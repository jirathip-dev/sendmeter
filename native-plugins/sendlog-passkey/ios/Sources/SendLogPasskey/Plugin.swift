import Foundation
import Capacitor
import AuthenticationServices

/// Runs the WebAuthn passkey ceremony natively so passkeys work inside the
/// Capacitor WebView. The WebView origin is capacitor://localhost, which the
/// browser WebAuthn API won't accept for the sendmeter.app RP ID; ASAuthorization
/// instead uses the `webcredentials:sendmeter.app` Associated Domain to scope the
/// credential. JS drives the two-step Supabase flow (start → this plugin →
/// verify); this plugin only performs the OS ceremony and returns the raw
/// credential fields as base64url (the encoding Supabase's endpoints expect).
///
/// One ceremony at a time: `pendingCall` + the retained controller are cleared
/// in the delegate callbacks. ASAuthorizationController must be created and run
/// on the main thread.
@objc(SendLogPasskey)
public class SendLogPasskey: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "SendLogPasskey"
    public let jsName = "SendLogPasskey"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isSupported", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "register", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "authenticate", returnType: CAPPluginReturnPromise)
    ]

    private var pendingCall: CAPPluginCall?
    private var controller: ASAuthorizationController?

    @objc func isSupported(_ call: CAPPluginCall) {
        if #available(iOS 16.0, *) {
            call.resolve(["supported": true])
        } else {
            call.resolve(["supported": false])
        }
    }

    @objc func register(_ call: CAPPluginCall) {
        guard #available(iOS 16.0, *) else {
            call.reject("Passkeys require iOS 16 or later")
            return
        }
        guard
            let rpId = call.getString("rpId"),
            let challengeStr = call.getString("challenge"),
            let userIdStr = call.getString("userId"),
            let userName = call.getString("userName"),
            let challenge = Self.base64URLDecode(challengeStr),
            let userId = Self.base64URLDecode(userIdStr)
        else {
            call.reject("Missing or invalid registration options")
            return
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: rpId)
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge, name: userName, userID: userId)
        perform([request], call: call)
    }

    @objc func authenticate(_ call: CAPPluginCall) {
        guard #available(iOS 16.0, *) else {
            call.reject("Passkeys require iOS 16 or later")
            return
        }
        guard
            let rpId = call.getString("rpId"),
            let challengeStr = call.getString("challenge"),
            let challenge = Self.base64URLDecode(challengeStr)
        else {
            call.reject("Missing or invalid authentication options")
            return
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: rpId)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        if let allowed = call.getArray("allowedCredentialIds", String.self), !allowed.isEmpty {
            request.allowedCredentials = allowed.compactMap { idStr in
                Self.base64URLDecode(idStr).map {
                    ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
                }
            }
        }
        perform([request], call: call)
    }

    @available(iOS 16.0, *)
    private func perform(_ requests: [ASAuthorizationRequest], call: CAPPluginCall) {
        if pendingCall != nil {
            call.reject("A passkey request is already in progress")
            return
        }
        pendingCall = call
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let controller = ASAuthorizationController(authorizationRequests: requests)
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    private func finish() {
        pendingCall = nil
        controller = nil
    }

    // Base64URL ⇄ Data. Supabase's WebAuthn endpoints speak base64url (no
    // padding, - and _ for + and /); ASAuthorization speaks Data.
    private static func base64URLDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = str.count % 4
        if rem > 0 { str += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: str)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@available(iOS 16.0, *)
extension SendLogPasskey: ASAuthorizationControllerDelegate {
    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let call = pendingCall
        finish()
        switch authorization.credential {
        case let reg as ASAuthorizationPlatformPublicKeyCredentialRegistration:
            guard let attestation = reg.rawAttestationObject else {
                call?.reject("Registration returned no attestation object")
                return
            }
            let id = Self.base64URLEncode(reg.credentialID)
            call?.resolve([
                "id": id,
                "rawId": id,
                "attestationObject": Self.base64URLEncode(attestation),
                "clientDataJSON": Self.base64URLEncode(reg.rawClientDataJSON)
            ])
        case let assertion as ASAuthorizationPlatformPublicKeyCredentialAssertion:
            let id = Self.base64URLEncode(assertion.credentialID)
            var result: [String: Any] = [
                "id": id,
                "rawId": id,
                "authenticatorData": Self.base64URLEncode(assertion.rawAuthenticatorData),
                "clientDataJSON": Self.base64URLEncode(assertion.rawClientDataJSON),
                "signature": Self.base64URLEncode(assertion.signature)
            ]
            if !assertion.userID.isEmpty {
                result["userHandle"] = Self.base64URLEncode(assertion.userID)
            }
            call?.resolve(result)
        default:
            call?.reject("Unexpected credential type")
        }
    }

    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        let call = pendingCall
        finish()
        // Surface cancellation as a "cancel" message so the JS layer can
        // swallow it silently (matches the browser NotAllowedError handling).
        if let asError = error as? ASAuthorizationError,
           asError.code == .canceled {
            call?.reject("Passkey ceremony canceled")
        } else {
            call?.reject(error.localizedDescription)
        }
    }
}

@available(iOS 16.0, *)
extension SendLogPasskey: ASAuthorizationControllerPresentationContextProviding {
    public func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        // Called on the main thread by AuthenticationServices.
        bridge?.viewController?.view.window ?? ASPresentationAnchor()
    }
}

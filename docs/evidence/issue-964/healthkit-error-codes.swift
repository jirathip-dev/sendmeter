import Foundation
#if canImport(HealthKit)
import HealthKit
print("HKErrorDomain:", HKErrorDomain)
print("authDenied:", HKError.Code.errorAuthorizationDenied.rawValue)
print("authNotDetermined:", HKError.Code.errorAuthorizationNotDetermined.rawValue)
print("dataUnavailable:", HKError.Code.errorHealthDataUnavailable.rawValue)
print("restricted:", HKError.Code.errorHealthDataRestricted.rawValue)
print("databaseInaccessible:", HKError.Code.errorDatabaseInaccessible.rawValue)
print("noData:", HKError.Code.errorNoData.rawValue)
print("userCanceled:", HKError.Code.errorUserCanceled.rawValue)
print("requiredAuthDenied:", HKError.Code.errorRequiredAuthorizationDenied.rawValue)
let e = NSError(domain: HKErrorDomain, code: 4)
print("bridged:", e.domain, e.code)
#else
print("no HealthKit")
#endif

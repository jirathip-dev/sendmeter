import Foundation
import XCTest
@testable import SendmeterWeather
import SendmeterCore

@MainActor
final class WeatherServiceTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    private var clock: TestClock!
    private var defaults: UserDefaults!
    private var location: StubLocationProvider!
    private var http: WeatherHTTPStub!
    private var session: URLSession!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        clock = TestClock(date: fixedDate)
        suiteName = "SendmeterWeatherTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        location = StubLocationProvider()
        http = WeatherHTTPStub()
        WeatherURLProtocol.install(http)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WeatherURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        WeatherURLProtocol.uninstall()
        defaults.removePersistentDomain(forName: suiteName)
        session = nil
        http = nil
        location = nil
        defaults = nil
        clock = nil
        super.tearDown()
    }

    func testCurrentSuccessPublishesWhenArchiveFails() async throws {
        http.enqueue(host: Self.forecastHost, result: .success(Self.currentPayload))
        http.enqueue(
            host: Self.archiveHost,
            result: .failure(URLError(.cannotLoadFromNetwork))
        )
        let service = makeService()

        let refreshed = await service.refresh()
        XCTAssertTrue(refreshed)

        let conditions = try XCTUnwrap(service.conditions)
        XCTAssertEqual(conditions.tempC, 25.3)
        XCTAssertEqual(conditions.humidity, 61)
        XCTAssertEqual(conditions.score, 13)
        XCTAssertNil(conditions.hist)
        XCTAssertNil(conditions.percentile)
        XCTAssertNil(conditions.daysBelow)
        XCTAssertNil(conditions.daysTotal)
        XCTAssertFalse(service.failed)
        XCTAssertEqual(location.callCount, 1)
        XCTAssertEqual(http.requestCount(forHost: Self.forecastHost), 1)
        XCTAssertEqual(http.requestCount(forHost: Self.archiveHost), 1)
    }

    func testSuccessfulCurrentClearsFailedAndPersistsSuccessfulFetchTimestamp() async throws {
        http.enqueue(
            host: Self.forecastHost,
            result: .failure(URLError(.notConnectedToInternet))
        )
        let service = makeService()

        let initialRefresh = await service.refresh()
        XCTAssertFalse(initialRefresh)
        XCTAssertTrue(service.failed)
        XCTAssertNil(service.conditions)

        let successfulDate = fixedDate.addingTimeInterval(11)
        clock.date = successfulDate
        http.enqueue(host: Self.forecastHost, result: .success(Self.currentPayload))
        http.enqueue(
            host: Self.archiveHost,
            result: .failure(URLError(.cannotLoadFromNetwork))
        )

        let successfulRefresh = await service.refresh(trigger: .manual)
        XCTAssertTrue(successfulRefresh)
        XCTAssertFalse(service.failed)
        XCTAssertEqual(service.conditions?.fetchedAt, successfulDate)

        let relaunched = makeService()
        XCTAssertEqual(relaunched.conditions?.fetchedAt, successfulDate)
        XCTAssertEqual(relaunched.conditions?.tempC, 25.3)
    }

    func testAutomaticLifecycleRefreshesInsideFreshnessWindowDoNoWork() async throws {
        enqueueSuccessfulCurrentAndArchive()
        let service = makeService()

        let initialRefresh = await service.refresh()
        XCTAssertTrue(initialRefresh)
        let initialLocationCalls = location.callCount
        let initialRequests = http.requestCount

        clock.date = fixedDate.addingTimeInterval(
            WeatherRefreshPolicy.defaultFreshnessWindow - 1
        )
        let appearRefresh = await service.refresh(trigger: .appear)
        let foregroundRefresh = await service.refresh(trigger: .foreground)
        XCTAssertTrue(appearRefresh)
        XCTAssertTrue(foregroundRefresh)

        XCTAssertEqual(location.callCount, initialLocationCalls)
        XCTAssertEqual(http.requestCount, initialRequests)
    }

    func testManualRefreshBypassesFreshnessWindow() async throws {
        enqueueSuccessfulCurrentAndArchive()
        let service = makeService()

        let initialRefresh = await service.refresh()
        XCTAssertTrue(initialRefresh)
        clock.date = fixedDate.addingTimeInterval(1)
        http.enqueue(host: Self.forecastHost, result: .success(Self.updatedCurrentPayload))

        let manualRefresh = await service.refresh(trigger: .manual)
        XCTAssertTrue(manualRefresh)

        XCTAssertEqual(location.callCount, 2)
        XCTAssertEqual(http.requestCount(forHost: Self.forecastHost), 2)
        XCTAssertEqual(service.conditions?.tempC, 18)
        XCTAssertEqual(service.conditions?.fetchedAt, clock.date)
    }

    func testFailedCurrentFetchDoesNotAdvanceFreshness() async throws {
        enqueueSuccessfulCurrentAndArchive()
        let service = makeService()

        let initialRefresh = await service.refresh()
        XCTAssertTrue(initialRefresh)
        let successfulDate = try XCTUnwrap(service.conditions?.fetchedAt)

        let failedDate = fixedDate.addingTimeInterval(10 * 60)
        clock.date = failedDate
        http.enqueue(
            host: Self.forecastHost,
            result: .failure(URLError(.timedOut))
        )
        let failedRefresh = await service.refresh(trigger: .manual)
        XCTAssertFalse(failedRefresh)
        XCTAssertEqual(service.conditions?.fetchedAt, successfulDate)

        // This is before the failed attempt's hypothetical freshness window,
        // but after the last successful reading's window. If the failure had
        // advanced the timestamp, this automatic refresh would be suppressed.
        let retryDate = failedDate.addingTimeInterval(
            WeatherRefreshPolicy.defaultFreshnessWindow - 1
        )
        clock.date = retryDate
        http.enqueue(host: Self.forecastHost, result: .success(Self.updatedCurrentPayload))
        let retryRefresh = await service.refresh(trigger: .appear)
        XCTAssertTrue(retryRefresh)

        XCTAssertEqual(location.callCount, 3)
        XCTAssertEqual(http.requestCount(forHost: Self.forecastHost), 3)
        XCTAssertEqual(service.conditions?.fetchedAt, retryDate)
    }

    private func makeService() -> WeatherService {
        WeatherService(
            defaults: defaults,
            session: session,
            locationProvider: location,
            now: { [clock] in clock!.date }
        )
    }

    private func enqueueSuccessfulCurrentAndArchive() {
        http.enqueue(host: Self.forecastHost, result: .success(Self.currentPayload))
        http.enqueue(host: Self.archiveHost, result: .success(Self.archivePayload))
    }

    private static let forecastHost = "api.open-meteo.com"
    private static let archiveHost = "archive-api.open-meteo.com"
    private static let currentPayload = Data(
        #"{"current":{"temperature_2m":25.3,"relative_humidity_2m":61}}"#.utf8
    )
    private static let updatedCurrentPayload = Data(
        #"{"current":{"temperature_2m":18,"relative_humidity_2m":40}}"#.utf8
    )
    private static let archivePayload = Data(
        #"{"hourly":{"temperature_2m":[6],"relative_humidity_2m":[0]}}"#.utf8
    )
}

@MainActor
private final class TestClock {
    var date: Date

    init(date: Date) {
        self.date = date
    }
}

@MainActor
private final class StubLocationProvider: WeatherLocationProviding {
    private(set) var callCount = 0

    func currentLocation() async throws -> (latitude: Double, longitude: Double) {
        callCount += 1
        return (13.75, 100.50)
    }
}

private final class WeatherHTTPStub {
    private let lock = NSLock()
    private var responses: [String: [Result<Data, Error>]] = [:]
    private var requests: [URLRequest] = []

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func enqueue(host: String, result: Result<Data, Error>) {
        lock.lock()
        responses[host, default: []].append(result)
        lock.unlock()
    }

    func requestCount(forHost host: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.url?.host == host }.count
    }

    func nextResponse(for request: URLRequest) -> Result<Data, Error> {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        let host = request.url?.host ?? ""
        guard !responses[host, default: []].isEmpty else {
            return .failure(URLError(.resourceUnavailable))
        }
        return responses[host]!.removeFirst()
    }
}

private final class WeatherURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var activeStub: WeatherHTTPStub?

    static func install(_ stub: WeatherHTTPStub) {
        lock.lock()
        activeStub = stub
        lock.unlock()
    }

    static func uninstall() {
        lock.lock()
        activeStub = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.open-meteo.com"
            || request.url?.host == "archive-api.open-meteo.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let stub = Self.activeStub
        Self.lock.unlock()

        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        switch stub.nextResponse(for: request) {
        case let .success(data):
            guard let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

import CoreLocation
import Combine
import Foundation
import SendmeterCore

/// Location seam for the weather path — injectable so tests never touch
/// CoreLocation.
@MainActor
public protocol WeatherLocationProviding {
    func currentLocation() async throws -> (latitude: Double, longitude: Double)
}

/// When-in-use location via CLLocationManager. The permission prompt is
/// deferred until the FIRST user-initiated check (web parity — the card
/// never prompts on a cold launch).
@MainActor
public final class CoreLocationWeatherLocationProvider: NSObject, WeatherLocationProviding,
    CLLocationManagerDelegate
{
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<(latitude: Double, longitude: Double), Error>?
    private var pendingPermissionRequest = false

    public override init() {
        super.init()
        // Coarse by design — the coordinates are rounded to ~1 km before the
        // Open-Meteo call, and the privacy manifest declares Coarse Location.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.delegate = self
    }

    public func currentLocation() async throws -> (latitude: Double, longitude: Double) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        case .notDetermined:
            pendingPermissionRequest = true
            manager.requestWhenInUseAuthorization()
        default:
            throw WeatherError.locationDenied
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.pendingPermissionRequest else { return }
            self.pendingPermissionRequest = false
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                break // requestLocation continues when the continuation is set
            default:
                self.continuation?.resume(throwing: WeatherError.locationDenied)
                self.continuation = nil
            }
        }
    }

    nonisolated public func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.continuation?.resume(returning: (location.coordinate.latitude, location.coordinate.longitude))
            self.continuation = nil
        }
    }

    nonisolated public func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }
}

/// "Send conditions" (SL-69, #631): fetches current temp + humidity from
/// Open-Meteo for the device's location and derives the 0–100 send score —
/// web parity. Coordinates are rounded to ~1 km before leaving the device
/// (the web rounds to 2 decimals), and the last reading + the weekly-bucketed
/// 30-day climate history are cached in UserDefaults. Honest failure: a
/// denied location or a failed fetch keeps the previous reading (labeled by
/// its `fetchedAt`) and reports failure when there is nothing to show —
/// never a fabricated score.
@MainActor
public final class WeatherService: ObservableObject {
    @Published public private(set) var conditions: SendConditions?
    @Published public private(set) var isFetching = false
    /// True when the last refresh failed AND there is no cached reading —
    /// the card renders "Unavailable" instead of inventing one.
    @Published public private(set) var failed = false

    private static let lastReadingKey = "sendmeter.native.weather.last-reading"
    private static let climateKey = "sendmeter.native.weather.climate"

    private let defaults: UserDefaults
    private let session: URLSession
    private let locationProvider: WeatherLocationProviding
    private let now: () -> Date
    private let refreshPolicy = WeatherRefreshPolicy()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        locationProvider: WeatherLocationProviding? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.session = session
        self.locationProvider = locationProvider ?? CoreLocationWeatherLocationProvider()
        self.now = now
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        if let cached = loadCached() {
            conditions = cached
        }
    }

    /// Fetch fresh conditions. Automatic calls skip a reading inside the
    /// freshness window; the default/manual trigger always tries. Returns
    /// false on failure (location denied, network error, empty payload) — the
    /// published `failed` flag covers the "nothing to show" case.
    @discardableResult
    public func refresh(trigger: WeatherRefreshTrigger = .manual) async -> Bool {
        let requestedAt = now()
        guard refreshPolicy.shouldRefresh(
            trigger: trigger,
            lastFetchedAt: conditions?.fetchedAt,
            now: requestedAt
        ) else {
            return conditions != nil
        }
        guard !isFetching else { return conditions != nil }
        isFetching = true
        defer { isFetching = false }
        do {
            let coords = try await locationProvider.currentLocation()
            let coordsKey = "\(String(format: "%.2f", coords.latitude)),\(String(format: "%.2f", coords.longitude))"
            let hourOfDay = Calendar.current.component(.hour, from: requestedAt)

            let current = try await fetchCurrent(latitude: coords.latitude, longitude: coords.longitude)
            let climate: ClimateSummary?
            do {
                climate = try await fetchClimate(
                    latitude: coords.latitude,
                    longitude: coords.longitude,
                    coordsKey: coordsKey,
                    referenceDate: requestedAt
                )
            } catch {
                // ERA5 is context only. A successful current reading remains
                // useful when the archive is unavailable, exactly like web.
                climate = nil
            }

            let fresh = SendConditionsScore.makeConditions(
                tempC: current.tempC,
                humidity: current.humidity,
                hourOfDay: hourOfDay,
                climate: climate,
                fetchedAt: now()
            )
            conditions = fresh
            failed = false
            persist(fresh, coordsKey: coordsKey)
            return true
        } catch {
            failed = conditions == nil
            return false
        }
    }

    /// A sign-out / account switch must not leak the previous user's cached
    /// reading into the next session's dashboard (called from
    /// `clearLoadedData`).
    public func resetForAccountChange() {
        conditions = nil
        failed = false
        defaults.removeObject(forKey: Self.lastReadingKey)
        defaults.removeObject(forKey: Self.climateKey)
    }

    private struct CachedReading: Codable {
        let coordsKey: String
        let conditions: SendConditions
    }

    private struct CachedClimate: Codable {
        let coordsKey: String
        let week: Int
        let summary: ClimateSummary
    }

    private func fetchCurrent(latitude: Double, longitude: Double) async throws -> (tempC: Double, humidity: Double) {
        let url = OpenMeteo.forecastURL(latitude: latitude, longitude: longitude)
        let data = try await get(url)
        let response = try decoder.decode(OpenMeteo.ForecastResponse.self, from: data)
        guard let reading = OpenMeteo.currentReading(from: response) else {
            throw WeatherError.unavailable
        }
        return (reading.tempC, reading.humidity)
    }

    private func fetchClimate(
        latitude: Double,
        longitude: Double,
        coordsKey: String,
        referenceDate: Date
    ) async throws -> ClimateSummary? {
        let week = SendConditionsScore.weekBucket(referenceDate)
        if let cached = cachedClimate(coordsKey: coordsKey, week: week) {
            return cached
        }
        let window = OpenMeteo.archiveDateWindow(referenceDate: referenceDate)
        let url = OpenMeteo.archiveURL(
            latitude: latitude,
            longitude: longitude,
            startDate: window.startDate,
            endDate: window.endDate
        )
        let data = try await get(url)
        let response = try decoder.decode(OpenMeteo.ArchiveResponse.self, from: data)
        guard let summary = OpenMeteo.climateSummary(from: response) else {
            throw WeatherError.unavailable
        }
        persistClimate(CachedClimate(coordsKey: coordsKey, week: week, summary: summary))
        return summary
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WeatherError.unavailable
        }
        return data
    }

    private func loadCached() -> SendConditions? {
        guard let raw = defaults.data(forKey: Self.lastReadingKey) else { return nil }
        guard let reading = try? decoder.decode(CachedReading.self, from: raw) else { return nil }
        return reading.conditions
    }

    private func persist(_ conditions: SendConditions, coordsKey: String) {
        guard let data = try? encoder.encode(
            CachedReading(coordsKey: coordsKey, conditions: conditions)
        ) else { return }
        defaults.set(data, forKey: Self.lastReadingKey)
    }

    private func cachedClimate(coordsKey: String, week: Int) -> ClimateSummary? {
        guard let raw = defaults.data(forKey: Self.climateKey) else { return nil }
        guard let cached = try? decoder.decode(CachedClimate.self, from: raw),
              cached.coordsKey == coordsKey, cached.week == week
        else { return nil }
        return cached.summary
    }

    private func persistClimate(_ cached: CachedClimate) {
        guard let data = try? encoder.encode(cached) else { return }
        defaults.set(data, forKey: Self.climateKey)
    }
}

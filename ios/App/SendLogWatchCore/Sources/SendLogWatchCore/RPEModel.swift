import Foundation

/// Ridge-regression RPE predictor fitted on-device from past workouts with a
/// confirmed RPE. Features mirror AttemptDetector.predictRPE: session HR
/// reserve, mean attempt effort, attempts per 10 minutes.
public nonisolated struct RPEModel: Codable {
    public let weights: [Double]  // [w_h, w_e, w_d, bias] on standardized features
    public let means: [Double]    // [μ_h, μ_e, μ_d]
    public let stds: [Double]     // [σ_h, σ_e, σ_d]
    public let sampleCount: Int
    public let fittedAt: Date

    public func predict(sessionHRR: Double, meanEffort: Double, attemptsPer10min: Double) -> Double {
        let x = [sessionHRR, meanEffort, attemptsPer10min]
        var y = weights[3]
        for j in 0..<3 {
            y += weights[j] * ((x[j] - means[j]) / stds[j])
        }
        return max(1, min(10, y))
    }
}

public nonisolated struct LabeledWorkout: Sendable {
    public let sessionHRR: Double       // 0..1, 0 when HR unavailable
    public let meanEffort: Double       // 0..10
    public let attemptsPer10min: Double
    public let rpe: Double              // confirmed label, 1..10

    public init(sessionHRR: Double, meanEffort: Double, attemptsPer10min: Double, rpe: Double) {
        self.sessionHRR = sessionHRR
        self.meanEffort = meanEffort
        self.attemptsPer10min = attemptsPer10min
        self.rpe = rpe
    }
}

public nonisolated enum RPEModelFitter {
    /// Solve (XᵀX + λ·diag(1,1,1,0)) w = Xᵀy on standardized features with an
    /// unregularized bias. Returns nil below minSamples or on degenerate data.
    public static func fit(rows: [LabeledWorkout], lambda: Double, minSamples: Int, now: Date = Date()) -> RPEModel? {
        guard rows.count >= minSamples else { return nil }
        let n = Double(rows.count)
        let raw = rows.map { [$0.sessionHRR, $0.meanEffort, $0.attemptsPer10min] }

        var means = [0.0, 0.0, 0.0]
        for x in raw { for j in 0..<3 { means[j] += x[j] / n } }
        var stds = [0.0, 0.0, 0.0]
        for x in raw { for j in 0..<3 { stds[j] += (x[j] - means[j]) * (x[j] - means[j]) / n } }
        for j in 0..<3 { stds[j] = stds[j].squareRoot(); if stds[j] < 1e-9 { stds[j] = 1 } }

        // Accumulate normal equations A = XᵀX + λD, b = Xᵀy over design rows
        // [z_h, z_e, z_d, 1].
        var A = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        var b = [Double](repeating: 0, count: 4)
        for (i, x) in raw.enumerated() {
            var d = [0.0, 0.0, 0.0, 1.0]
            for j in 0..<3 { d[j] = (x[j] - means[j]) / stds[j] }
            let y = rows[i].rpe
            for j in 0..<4 {
                b[j] += d[j] * y
                for k in 0..<4 { A[j][k] += d[j] * d[k] }
            }
        }
        for j in 0..<3 { A[j][j] += lambda }

        guard let w = solve4x4(A, b) else { return nil }
        return RPEModel(weights: w, means: means, stds: stds, sampleCount: rows.count, fittedAt: now)
    }

    /// Gaussian elimination with partial pivoting; nil when near-singular.
    public static func solve4x4(_ mat: [[Double]], _ rhs: [Double]) -> [Double]? {
        var a = mat
        var b = rhs
        for col in 0..<4 {
            var pivotRow = col
            for r in (col + 1)..<4 where abs(a[r][col]) > abs(a[pivotRow][col]) {
                pivotRow = r
            }
            if abs(a[pivotRow][col]) < 1e-9 { return nil }
            if pivotRow != col {
                a.swapAt(pivotRow, col)
                b.swapAt(pivotRow, col)
            }
            for r in (col + 1)..<4 {
                let f = a[r][col] / a[col][col]
                for c in col..<4 { a[r][c] -= f * a[col][c] }
                b[r] -= f * b[col]
            }
        }
        var w = [Double](repeating: 0, count: 4)
        for row in stride(from: 3, through: 0, by: -1) {
            var s = b[row]
            for c in (row + 1)..<4 { s -= a[row][c] * w[c] }
            w[row] = s / a[row][row]
        }
        return w
    }
}

/// Rounding policy for banking a model-predicted RPE (#107). The
/// auto-tracked save paths — `WorkoutLiveView.endAndSave` and, since #280,
/// the gauge session's W'-depletion prediction (`RPEDepletion`) — bank the
/// raw prediction at 0.1 precision, no rounding to half-points. That's
/// distinct from the MANUAL RPE steppers (phone/web log forms), which
/// intentionally still move in 0.5 steps; don't reuse this for those.
public nonisolated enum RPEQuantization {
    public static func autoTracked(_ predicted: Double) -> Double {
        (min(10, max(1, predicted)) * 10).rounded() / 10
    }
}

public nonisolated enum RPEModelStore {
    // #473/#478: bumped from "rpeModel.v1" — every model fitted before this
    // fix trained on #473's corrupt features (a 27s boulder recorded as
    // 1034s, 5 boulders recorded as 1, `attempts_confirmed` systematically
    // under-counted). Bumping the key makes `load()` read nil once on
    // upgrade, so `refitRPEModelIfStale` treats it as unconditionally stale
    // and refits from scratch on the next workout start — an old-key model
    // is simply never read again, "clearing" it without needing a migration.
    // Historical-row policy (decided, not backfilled): existing
    // `climb_workouts`/`climb_attempts` rows from before this fix keep their
    // recorded (sometimes phantom) durations/counts — see RELEASE_NOTES.md.
    // Any future refit still trains on that history, but the corrupt SHAPE
    // this bug produced (near-permanent CLIMBING, 1 merged attempt) should
    // become rare going forward, and each refit requires
    // rpeMinTrainingSamples confirmed workouts, diluting old outliers as new
    // (correct) ones accumulate.
    private static let key = "rpeModel.v2"

    public static func load() -> RPEModel? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RPEModel.self, from: data)
    }

    public static func save(_ model: RPEModel) {
        if let data = try? JSONEncoder().encode(model) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

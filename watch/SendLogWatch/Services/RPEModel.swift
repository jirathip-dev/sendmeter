import Foundation

/// Ridge-regression RPE predictor fitted on-device from past workouts with a
/// confirmed RPE. Features mirror AttemptDetector.predictRPE: session HR
/// reserve, mean attempt effort, attempts per 10 minutes.
struct RPEModel: Codable {
    let weights: [Double]  // [w_h, w_e, w_d, bias] on standardized features
    let means: [Double]    // [μ_h, μ_e, μ_d]
    let stds: [Double]     // [σ_h, σ_e, σ_d]
    let sampleCount: Int
    let fittedAt: Date

    func predict(sessionHRR: Double, meanEffort: Double, attemptsPer10min: Double) -> Double {
        let x = [sessionHRR, meanEffort, attemptsPer10min]
        var y = weights[3]
        for j in 0..<3 {
            y += weights[j] * ((x[j] - means[j]) / stds[j])
        }
        return max(1, min(10, y))
    }
}

struct LabeledWorkout {
    let sessionHRR: Double       // 0..1, 0 when HR unavailable
    let meanEffort: Double       // 0..10
    let attemptsPer10min: Double
    let rpe: Double              // confirmed label, 1..10
}

enum RPEModelFitter {
    /// Solve (XᵀX + λ·diag(1,1,1,0)) w = Xᵀy on standardized features with an
    /// unregularized bias. Returns nil below minSamples or on degenerate data.
    static func fit(rows: [LabeledWorkout], lambda: Double, minSamples: Int, now: Date = Date()) -> RPEModel? {
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
    static func solve4x4(_ mat: [[Double]], _ rhs: [Double]) -> [Double]? {
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

enum RPEModelStore {
    private static let key = "rpeModel.v1"

    static func load() -> RPEModel? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RPEModel.self, from: data)
    }

    static func save(_ model: RPEModel) {
        if let data = try? JSONEncoder().encode(model) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

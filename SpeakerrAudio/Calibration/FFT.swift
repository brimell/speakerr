import Foundation

enum FFT {
    static func convolve(_ lhs: [Double], _ rhs: [Double]) -> [Double] {
        guard !lhs.isEmpty, !rhs.isEmpty else { return [] }
        let resultCount = lhs.count + rhs.count - 1
        var size = 1
        while size < resultCount { size <<= 1 }
        var lhsReal = lhs + repeatElement(0, count: size - lhs.count)
        var lhsImag = [Double](repeating: 0, count: size)
        var rhsReal = rhs + repeatElement(0, count: size - rhs.count)
        var rhsImag = [Double](repeating: 0, count: size)
        transform(real: &lhsReal, imaginary: &lhsImag, inverse: false)
        transform(real: &rhsReal, imaginary: &rhsImag, inverse: false)
        for index in 0..<size {
            let real = lhsReal[index] * rhsReal[index] - lhsImag[index] * rhsImag[index]
            let imaginary = lhsReal[index] * rhsImag[index] + lhsImag[index] * rhsReal[index]
            lhsReal[index] = real
            lhsImag[index] = imaginary
        }
        transform(real: &lhsReal, imaginary: &lhsImag, inverse: true)
        return Array(lhsReal.prefix(resultCount))
    }

    private static func transform(real: inout [Double], imaginary: inout [Double], inverse: Bool) {
        let count = real.count
        var target = 0
        for index in 1..<count {
            var bit = count >> 1
            while target & bit != 0 {
                target ^= bit
                bit >>= 1
            }
            target ^= bit
            if index < target {
                real.swapAt(index, target)
                imaginary.swapAt(index, target)
            }
        }

        var length = 2
        while length <= count {
            let angle = (inverse ? 2.0 : -2.0) * Double.pi / Double(length)
            let stepReal = cos(angle)
            let stepImaginary = sin(angle)
            for start in stride(from: 0, to: count, by: length) {
                var twiddleReal = 1.0
                var twiddleImaginary = 0.0
                for offset in 0..<(length / 2) {
                    let even = start + offset
                    let odd = even + length / 2
                    let oddReal = real[odd] * twiddleReal - imaginary[odd] * twiddleImaginary
                    let oddImaginary = real[odd] * twiddleImaginary + imaginary[odd] * twiddleReal
                    real[odd] = real[even] - oddReal
                    imaginary[odd] = imaginary[even] - oddImaginary
                    real[even] += oddReal
                    imaginary[even] += oddImaginary
                    let nextReal = twiddleReal * stepReal - twiddleImaginary * stepImaginary
                    twiddleImaginary = twiddleReal * stepImaginary + twiddleImaginary * stepReal
                    twiddleReal = nextReal
                }
            }
            length <<= 1
        }
        if inverse {
            let scale = 1.0 / Double(count)
            for index in 0..<count {
                real[index] *= scale
                imaginary[index] *= scale
            }
        }
    }
}

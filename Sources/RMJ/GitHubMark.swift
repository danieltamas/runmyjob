import SwiftUI

/// The GitHub mark (Octicons `mark-github`, MIT), drawn as a path so it takes the text colour like an SF Symbol.
struct GitHubMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 8.000, y: 0.000))
        p.addCurve(to: CGPoint(x: 0.000, y: 8.000), control1: CGPoint(x: 3.580, y: 0.000), control2: CGPoint(x: 0.000, y: 3.580))
        p.addCurve(to: CGPoint(x: 5.470, y: 15.590), control1: CGPoint(x: 0.000, y: 11.540), control2: CGPoint(x: 2.290, y: 14.530))
        p.addCurve(to: CGPoint(x: 6.020, y: 15.210), control1: CGPoint(x: 5.870, y: 15.660), control2: CGPoint(x: 6.020, y: 15.420))
        p.addCurve(to: CGPoint(x: 6.010, y: 13.720), control1: CGPoint(x: 6.020, y: 15.020), control2: CGPoint(x: 6.010, y: 14.390))
        p.addCurve(to: CGPoint(x: 3.320, y: 12.780), control1: CGPoint(x: 4.000, y: 14.090), control2: CGPoint(x: 3.480, y: 13.230))
        p.addCurve(to: CGPoint(x: 2.500, y: 11.650), control1: CGPoint(x: 3.230, y: 12.550), control2: CGPoint(x: 2.840, y: 11.840))
        p.addCurve(to: CGPoint(x: 2.490, y: 11.120), control1: CGPoint(x: 2.220, y: 11.500), control2: CGPoint(x: 1.820, y: 11.130))
        p.addCurve(to: CGPoint(x: 3.720, y: 11.940), control1: CGPoint(x: 3.120, y: 11.110), control2: CGPoint(x: 3.570, y: 11.700))
        p.addCurve(to: CGPoint(x: 6.050, y: 12.600), control1: CGPoint(x: 4.440, y: 13.150), control2: CGPoint(x: 5.590, y: 12.810))
        p.addCurve(to: CGPoint(x: 6.560, y: 11.530), control1: CGPoint(x: 6.120, y: 12.080), control2: CGPoint(x: 6.330, y: 11.730))
        p.addCurve(to: CGPoint(x: 2.920, y: 7.580), control1: CGPoint(x: 4.780, y: 11.330), control2: CGPoint(x: 2.920, y: 10.640))
        p.addCurve(to: CGPoint(x: 3.740, y: 5.430), control1: CGPoint(x: 2.920, y: 6.710), control2: CGPoint(x: 3.230, y: 5.990))
        p.addCurve(to: CGPoint(x: 3.820, y: 3.310), control1: CGPoint(x: 3.660, y: 5.230), control2: CGPoint(x: 3.380, y: 4.410))
        p.addCurve(to: CGPoint(x: 6.020, y: 4.130), control1: CGPoint(x: 3.820, y: 3.310), control2: CGPoint(x: 4.490, y: 3.100))
        p.addCurve(to: CGPoint(x: 8.020, y: 3.860), control1: CGPoint(x: 6.660, y: 3.950), control2: CGPoint(x: 7.340, y: 3.860))
        p.addCurve(to: CGPoint(x: 10.020, y: 4.130), control1: CGPoint(x: 8.700, y: 3.860), control2: CGPoint(x: 9.380, y: 3.950))
        p.addCurve(to: CGPoint(x: 12.220, y: 3.310), control1: CGPoint(x: 11.550, y: 3.090), control2: CGPoint(x: 12.220, y: 3.310))
        p.addCurve(to: CGPoint(x: 12.300, y: 5.430), control1: CGPoint(x: 12.660, y: 4.410), control2: CGPoint(x: 12.380, y: 5.230))
        p.addCurve(to: CGPoint(x: 13.120, y: 7.580), control1: CGPoint(x: 12.810, y: 5.990), control2: CGPoint(x: 13.120, y: 6.700))
        p.addCurve(to: CGPoint(x: 9.470, y: 11.530), control1: CGPoint(x: 13.120, y: 10.650), control2: CGPoint(x: 11.250, y: 11.330))
        p.addCurve(to: CGPoint(x: 10.010, y: 13.010), control1: CGPoint(x: 9.760, y: 11.780), control2: CGPoint(x: 10.010, y: 12.260))
        p.addCurve(to: CGPoint(x: 10.000, y: 15.210), control1: CGPoint(x: 10.010, y: 14.080), control2: CGPoint(x: 10.000, y: 14.940))
        p.addCurve(to: CGPoint(x: 10.550, y: 15.590), control1: CGPoint(x: 10.000, y: 15.420), control2: CGPoint(x: 10.150, y: 15.670))
        p.addLine(to: CGPoint(x: 11.700, y: 15.108))
        p.addLine(to: CGPoint(x: 12.758, y: 14.447))
        p.addLine(to: CGPoint(x: 13.701, y: 13.631))
        p.addLine(to: CGPoint(x: 14.506, y: 12.678))
        p.addLine(to: CGPoint(x: 15.153, y: 11.611))
        p.addLine(to: CGPoint(x: 15.627, y: 10.457))
        p.addLine(to: CGPoint(x: 15.916, y: 9.244))
        p.addLine(to: CGPoint(x: 16.013, y: 8.000))
        p.addCurve(to: CGPoint(x: 8.000, y: 0.000), control1: CGPoint(x: 16.000, y: 3.580), control2: CGPoint(x: 12.420, y: 0.000))
        p.closeSubpath()
        let s = min(rect.width, rect.height) / 16
        return p.applying(CGAffineTransform(scaleX: s, y: s)).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

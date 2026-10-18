import SwiftUI

/// Hiển thị ảnh (aspect fit) và khoanh tròn các lỗi theo toạ độ 0–1000.
struct AnnotatedImageView: View {
    let image: UIImage
    let errors: [InspectionResult.InstallError]
    var selected: Int?

    var body: some View {
        GeometryReader { geo in
            let rect = fittedRect(image.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                ForEach(Array(errors.enumerated()), id: \.offset) { i, e in
                    let cx = rect.minX + e.x / 1000 * rect.width
                    let cy = rect.minY + e.y / 1000 * rect.height
                    let r = max(e.radius / 1000 * max(rect.width, rect.height), 14)
                    let isSel = selected == i

                    Circle()
                        .stroke(Color.red, lineWidth: isSel ? 5 : 3)
                        .frame(width: r * 2, height: r * 2)
                        .position(x: cx, y: cy)
                        .shadow(color: .black.opacity(0.5), radius: 2)

                    Text("\(i + 1)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(Color.red))
                        .position(x: min(cx + r * 0.75, rect.maxX - 10), y: max(cy - r * 0.75, rect.minY + 10))
                }
            }
        }
        .aspectRatio(image.size, contentMode: .fit)
    }

    private func fittedRect(_ img: CGSize, in box: CGSize) -> CGRect {
        let s = min(box.width / img.width, box.height / img.height)
        let w = img.width * s, h = img.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }
}

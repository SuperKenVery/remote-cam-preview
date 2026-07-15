import SwiftUI

struct MonitorScreen: View {
    let session: AppSession
    let mediaPipeline: MediaPipeline

    var body: some View {
        GeometryReader { proxy in
            let viewportSize = Self.aspectFitSize(
                aspectRatio: previewAspectRatio,
                inside: proxy.size
            )

            ZStack {
                Color(uiColor: .systemBackground)

                ZStack {
                    Color.black
                    RemoteVideoView(renderer: mediaPipeline.renderer)

                    if !mediaPipeline.renderer.hasFrame {
                        ContentUnavailableView {
                            Label("等待预览", systemImage: "video.slash")
                        } description: {
                            Text("连接后将按拍摄端传来的宽高比显示完整画面。")
                        }
                        .foregroundStyle(.white)
                    }
                }
                .frame(width: viewportSize.width, height: viewportSize.height)
            }
        }
    }

    private var previewAspectRatio: CGFloat {
        guard let dimensions = session.selectedPreviewConfiguration?.dimensions,
              dimensions.width > 0, dimensions.height > 0
        else { return 3 / 4 }
        return CGFloat(dimensions.width) / CGFloat(dimensions.height)
    }

    private static func aspectFitSize(aspectRatio: CGFloat, inside bounds: CGSize) -> CGSize {
        guard aspectRatio > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let availableRatio = bounds.width / bounds.height
        if availableRatio > aspectRatio {
            return CGSize(width: bounds.height * aspectRatio, height: bounds.height)
        }
        return CGSize(width: bounds.width, height: bounds.width / aspectRatio)
    }
}

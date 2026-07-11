import SwiftUI

struct MonitorScreen: View {
    let session: AppSession
    let mediaPipeline: MediaPipeline

    var body: some View {
        ZStack {
            Color.black

            RemoteVideoView(renderer: mediaPipeline.renderer)
                .aspectRatio(contentMode: .fill)
                .clipped()

            if !mediaPipeline.renderer.hasFrame {
                ContentUnavailableView {
                    Label("等待预览", systemImage: "video.slash")
                } description: {
                    Text("连接后将以正确宽高比居中裁切，优先保持低延迟。")
                }
                .foregroundStyle(.white)
            }
        }
    }
}


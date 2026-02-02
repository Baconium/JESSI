//
//  RemoteImage.swift
//  JESSI
//  AsyncImage for iOS 14 basically
//
//  Created by roooot on 01.02.26.
//

import SwiftUI

struct RemoteImage: View {
    let url: URL?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
            } else {
                ZStack {
                    Color.gray.opacity(0.3)
                        .onAppear(perform: load)
                    ProgressView()
                }
            }
        }
    }

    private func load() {
        guard image == nil, let url = url else { return }

        let request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 30
        )

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let uiImage = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                image = uiImage
            }
        }.resume()
    }
}

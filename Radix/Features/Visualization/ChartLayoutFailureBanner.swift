//
//  ChartLayoutFailureBanner.swift
//  Radix
//

import SwiftUI

struct ChartLayoutFailureBanner: View {
    let failure: ChartLayoutFailure
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn’t Load Disk Map", tableName: "Interface")
                    .font(.headline)
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: retry) {
                Text("Retry", tableName: "Interface")
            }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint(
                    Text("Attempts to load the disk map again.", tableName: "Interface")
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Disk map layout failed", tableName: "Interface"))
    }
}

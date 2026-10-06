//
//  ServerMonitorFloatingView.swift
//  Minis
//
//  MinisVPS: the small translucent floating server monitor card pinned to the
//  bottom-trailing corner of the main app window. It shows four live mini
//  gauges (CPU / 内存 / 磁盘 / 负载), can be:
//    - tapped to expand into the full detail card (network, uptime, cores,
//      memory & disk breakdown, and a link to the quick-actions panel),
//    - dragged to reposition within safe bounds,
//    - toggled on/off via the `minisVPSEnabled` AppStorage switch.
//
//  iOS 16+ / Swift 6: single-argument onChange, DRAGGED via DragGesture,
//  material background `.ultraThinMaterial`, SF Symbols only.
//

import SwiftUI

/// The draggable, collapsible floating monitor window.
struct ServerMonitorFloatingView: View {
    @ObservedObject private var monitor = ServerMonitor.shared
    /// Master switch (App Settings → not exposed directly; default ON).
    @AppStorage("minisVPSEnabled") private var enabled: Bool = true

    @State private var expanded = false
    @State private var showActions = false

    // Drag state: `savedOffset` is the settled position, `dragOffset` the
    // live translation during the gesture.
    @State private var savedOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @GestureState private var isDragging = false

    var body: some View {
        if enabled {
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    if expanded {
                        expandedContent
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                    } else {
                        collapsedContent
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                    }
                }
                .frame(maxWidth: 360)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.7)
                )
                .shadow(color: .black.opacity(0.18), radius: isDragging ? 8 : 14, y: 5)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .offset(x: dragOffset.width, y: dragOffset.height)
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .updating($isDragging) { _, state, _ in state = true }
                        .onChanged { value in
                            let t = CGSize(width: savedOffset.width + value.translation.width,
                                           height: savedOffset.height + value.translation.height)
                            dragOffset = clamped(t)
                        }
                        .onEnded { value in
                            let final = clamped(CGSize(width: savedOffset.width + value.translation.width,
                                                       height: savedOffset.height + value.translation.height))
                            savedOffset = final
                            dragOffset = final
                        }
                        .simultaneously(with: TapGesture().onEnded {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                expanded.toggle()
                            }
                        })
                )
                .onChange(of: expanded) { newValue in
                    monitor.setWantsFullDetail(newValue)
                }
            }
            .ignoresSafeArea(.keyboard)
            .onAppear { monitor.startMonitoring() }
            .onDisappear { monitor.stopMonitoring() }
            .sheet(isPresented: $showActions) {
                ServerQuickActionsView()
            }
        }
    }


    // MARK: - Sizing
    // MARK: - Collapsed layout
    private var collapsedContent: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(monitor.host)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(monitor.isRunning ? "● LIVE" : "○ STOP")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(monitor.isRunning ? .green : .secondary)
                }
            }
            .frame(width: 86, alignment: .leading)

            MiniGauge(label: "CPU",   value: monitor.cpu,   color: .orange)
            MiniGauge(label: "内存",   value: monitor.mem,   color: .blue)
            MiniGauge(label: "磁盘",   value: monitor.disk,  color: .purple)
            MiniGauge(label: "负载",   value: monitor.load,  color: .teal)
        }
    }

    // MARK: - Expanded layout
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(monitor.host)
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                        Text("Uptime  \(monitor.uptime)")
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    showActions = true
                } label: {
                    Image(systemName: "bolt.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 28, height: 28)
                        .background(.blue.opacity(0.12), in: Circle())
                }
            }

            // Main 2x2 gauge grid
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                LargeGauge(label: "CPU 使用率", value: monitor.cpu,  symbol: "cpu",       color: .orange)
                LargeGauge(label: "内存",      value: monitor.mem,  symbol: "memorychip", color: .blue)
                LargeGauge(label: "磁盘",      value: monitor.disk, symbol: "internaldrive", color: .purple)
                LargeGauge(label: "系统负载",   value: monitor.load, symbol: "gauge.with.dots.needle.50percent", color: .teal)
            }

            // Network flow row
            HStack(spacing: 10) {
                StatChip(symbol: "arrow.down.circle",   label: "下行", value: monitor.netRx, color: .green)
                StatChip(symbol: "arrow.up.circle",     label: "上行", value: monitor.netTx, color: .orange)
                StatChip(symbol: "cpu",                 label: "核心", value: "\(monitor.cores)", color: .indigo)
            }

            // Memory / disk breakdown
            HStack(spacing: 10) {
                BreakdownRow(symbol: "memorychip",
                             used: monitor.memUsed,
                             total: monitor.memTotal,
                             percent: monitor.mem,
                             color: .blue)
                BreakdownRow(symbol: "internaldrive",
                             used: monitor.diskUsed,
                             total: monitor.diskTotal,
                             percent: monitor.disk,
                             color: .purple)
            }
        }
    }

    // MARK: - Drag helpers
    /// Current rendered card size (collapsed and expanded differ).
    private func cardSize() -> CGSize {
        let w = min(UIScreen.main.bounds.width - 16, expanded ? 350 : 320)
        let h = expanded ? 360 : 58
        return CGSize(width: w, height: h)
    }

    /// Clamp the drag offset so the card stays fully on-screen.
    /// Offset (0,0) anchors the card at the bottom-trailing corner.
    private func clamped(_ c: CGSize) -> CGSize {
        let inset: CGFloat = 8
        let size = cardSize()
        let sw = UIScreen.main.bounds.width
        let sh = UIScreen.main.bounds.height
        let minX = -(sw - size.width - inset)
        let maxX = 0.0
        let minY = -(sh - size.height - inset)
        let maxY = 0.0
        let dx = min(maxX, max(minX, c.width))
        let dy = min(maxY, max(minY, c.height))
        return CGSize(width: dx, height: dy)
    }
}


// MARK: - Mini horizontal gauge (collapsed)
private struct MiniGauge: View {
    let label: String
    let value: Double
    let color: Color
    private var clamped: Double { min(max(value, 0), 100) / 100 }

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
            CapsuleBar(value: clamped, color: color)
            Text(MonitorFormat.percent(value))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Larger ring gauge (expanded)
private struct LargeGauge: View {
    let label: String
    let value: Double
    let symbol: String
    let color: Color
    private var clamped: Double { min(max(value, 0), 100) / 100 }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.15), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: clamped)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(MonitorFormat.percent(value))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Tiny stat chip (network / cores)
private struct StatChip: View {
    let symbol: String
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Memory / disk breakdown
private struct BreakdownRow: View {
    let symbol: String
    let used: String
    let total: String
    let percent: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                Text("\(used) / \(total)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            }
            CapsuleBar(value: min(max(percent, 0), 100) / 100, color: color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Reusable thin capsule progress bar
private struct CapsuleBar: View {
    let value: Double   // 0...1
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))
                Capsule()
                    .fill(color)
                    .frame(width: max(2, geo.size.width * value))
            }
        }
        .frame(height: 4)
    }
}
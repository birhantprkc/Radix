// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RadixCore",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .library(
            name: "RadixCore",
            targets: ["RadixCore"]
        )
    ],
    targets: [
        .target(
            name: "RadixCore",
            path: "Radix",
            exclude: [
                "App",
                "AppIcon.icon",
                "Assets.xcassets",
                "ContentView.swift",
                "Features",
                "InfoPlist.xcstrings",
                "Info.plist",
                "Localizable.xcstrings",
                "RadixApp.swift",
                "Shared"
            ],
            sources: [
                "Models/FileNodeActions.swift",
                "Models/FileNodeRecord.swift",
                "Models/FileTreeStore.swift",
                "Models/ScanProgress.swift",
                "Models/ScanSnapshot.swift",
                "Models/ScanTarget.swift",
                "Models/TrashSafetyPolicy.swift",
                "Services/AtomicDirectoryParallelSummary.swift",
                "Services/AtomicDirectorySummaryPool.swift",
                "Services/AtomicDirectorySummaryProbe.swift",
                "Services/AtomicDirectorySummaryWalker.swift",
                "Services/AtomicDirectorySummarizer.swift",
                "Services/AtomicDirectorySummaryModels.swift",
                "Services/BulkDirectoryEnumerator.swift",
                "Services/AppDependencies.swift",
                "Services/AppPreferencesStore.swift",
                "Services/AppSystemActions.swift",
                "Services/AppUsageStatsStore.swift",
                "Services/FileBrowserDisplayState.swift",
                "Services/FileBrowserModel.swift",
                "Services/FileBrowserResults.swift",
                "Services/FileBrowserSearch.swift",
                "Services/FileBrowserSorting.swift",
                "Services/FileSizeFormatter.swift",
                "Services/FileSystemEventHistory.swift",
                "Services/HardLinkDeduplicator.swift",
                "Services/HardLinkIdentityOwnerAccumulator.swift",
                "Services/IncrementalRescanPlanner.swift",
                "Services/IncrementalScanService.swift",
                "Services/PackageClassifier.swift",
                "Services/QuickLookIntegration.swift",
                "Services/RecentTargetStore.swift",
                "Services/ScanArchiveModels.swift",
                "Services/ScanArchiveNodeIO.swift",
                "Services/ScanArchiveProgressReporting.swift",
                "Services/ScanArchiveService.swift",
                "Services/ScanArchiveTopologyValidator.swift",
                "Services/ScanComparisonProjection.swift",
                "Services/ScanComparisonQuery.swift",
                "Services/ScanComparisonService.swift",
                "Services/ScanDiagnostics.swift",
                "Services/ScanDirectoryDescriptorPool.swift",
                "Services/ScanDirectoryEntryFilter.swift",
                "Services/ScanCoordinator.swift",
                "Services/ScanEngine.swift",
                "Services/ScanExclusionMatcher.swift",
                "Services/ScanIncrementalModels.swift",
                "Services/ScanMetadataLoader.swift",
                "Services/ScanSnapshotTransformService.swift",
                "Services/ScanWarningFactory.swift",
                "Services/SunburstChartModel.swift",
                "Services/SunburstColorResolver.swift",
                "Services/DiskMapFreeSpaceVisualization.swift",
                "Services/SunburstGeometry.swift",
                "Services/DiskMapVisualizationFilterModel.swift",
                "Services/SunburstViewportTransform.swift",
                "Services/SystemIntegration.swift",
                "Services/TreemapChartModel.swift",
                "Services/TreemapColorResolver.swift",
                "Services/TreemapGeometry.swift",
                "Services/TreemapTooltipContent.swift",
                "Services/TreemapTooltipPlacement.swift",
                "ViewModels/AppQuickLookController.swift",
                "ViewModels/AppModel.swift",
                "ViewModels/ScanComparisonSetup.swift",
                "ViewModels/SidebarScanCacheController.swift",
                "ViewModels/SidebarModel.swift",
                "ViewModels/WorkspaceNavigationModel.swift"
            ]
        ),
        .testTarget(
            name: "RadixCoreTests",
            dependencies: ["RadixCore"],
            path: "RadixCoreTests"
        )
    ]
)

import Foundation

public enum SupportedModelSource {
    public static let displayName = "Huihui Gemma 4 26B-A4B IT Abliterated 4-bit"
    public static let repoID = "raver1975/Huihui-gemma-4-26B-A4B-it-abliterated-4bit"
    public static let revision = "d1d6ff720a7100dd58fa624bd0576276dc5603ea"
    public static let sourceIndexSHA256 =
        "df3133d5e9e400092664cb2197413a32035189ab7c41f4b000f75a284abdc512"
    public static let approximateDownloadBytes: UInt64 = 14_200_000_000
    public static let installedBytes: UInt64 = 14_291_921_884
    public static let reserveBytes: UInt64 = 1_073_741_824

    public static func installOptions(outputDirectory: URL,
                                      overwrite: Bool,
                                      token: String?,
                                      resume: Bool = false)
        -> RemoteStreamingRepackOptions {
        RemoteStreamingRepackOptions(
            repoID: repoID,
            revision: revision,
            outputDir: outputDirectory.path,
            token: token,
            requireKnownSource: true,
            minFreeReserveBytes: reserveBytes,
            overwrite: overwrite,
            resume: resume)
    }
}

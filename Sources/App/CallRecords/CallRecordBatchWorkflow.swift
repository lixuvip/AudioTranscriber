import Foundation

enum TranscriptionRunContext: String, Equatable {
    case interactive
    case callRecordBatch
}

enum CallRecordBatchPostTranscriptionAction: Equatable {
    case summarize
    case fail(String)
    case cancel
}

enum CallRecordBatchWorkflow {
    static func shouldOpenEditor(
        context: TranscriptionRunContext,
        speakerRolesReady: Bool
    ) -> Bool {
        speakerRolesReady && context == .interactive
    }

    static func postTranscriptionAction(
        success: Bool,
        cancelled: Bool,
        errorMessage: String?,
        hasSummaryModel: Bool
    ) -> CallRecordBatchPostTranscriptionAction {
        if cancelled {
            return .cancel
        }
        guard success else {
            return .fail(errorMessage ?? "转写失败")
        }
        guard hasSummaryModel else {
            return .fail("未配置 AI 摘要模型")
        }
        return .summarize
    }
}

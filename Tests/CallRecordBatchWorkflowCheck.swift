import Foundation

@main
struct CallRecordBatchWorkflowCheck {
    static func main() {
        assertEqual(
            CallRecordBatchWorkflow.shouldOpenEditor(
                context: .interactive,
                speakerRolesReady: true
            ),
            true,
            "interactive transcription opens editor"
        )
        assertEqual(
            CallRecordBatchWorkflow.shouldOpenEditor(
                context: .callRecordBatch,
                speakerRolesReady: true
            ),
            false,
            "batch transcription stays on queue"
        )
        assertEqual(
            CallRecordBatchWorkflow.postTranscriptionAction(
                success: true,
                cancelled: false,
                errorMessage: nil,
                hasSummaryModel: true
            ),
            .summarize,
            "successful batch transcription starts summary"
        )
        assertEqual(
            CallRecordBatchWorkflow.postTranscriptionAction(
                success: true,
                cancelled: false,
                errorMessage: nil,
                hasSummaryModel: false
            ),
            .fail("未配置 AI 摘要模型"),
            "missing summary model fails explicitly"
        )
        assertEqual(
            CallRecordBatchWorkflow.postTranscriptionAction(
                success: false,
                cancelled: true,
                errorMessage: "用户停止",
                hasSummaryModel: true
            ),
            .cancel,
            "cancelled transcription stays cancelled"
        )
    }

    private static func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
        if lhs != rhs {
            fatalError("\(message): expected \(rhs), got \(lhs)")
        }
    }
}

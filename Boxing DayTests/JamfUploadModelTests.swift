import Foundation
import XCTest
@testable import Boxing_Day

@MainActor
final class JamfUploadModelTests: XCTestCase {
    private let packageURL = URL(fileURLWithPath: "/tmp/Example App 1.0.pkg")
    private let configuration = JamfConfiguration(
        serverURL: "https://example.jamfcloud.com",
        clientID: "example-client"
    )

    private func connectedModel() -> JamfUploadModel {
        let model = JamfUploadModel(packageURL: packageURL)
        model.useConnection(configuration, clientSecret: "example-secret")
        return model
    }

    // MARK: - Initial fields

    func testFieldsStartFromTheSuggestedFilename() {
        let model = JamfUploadModel(
            packageURL: packageURL,
            suggestedFileName: "Example App 1.0.1.pkg"
        )

        XCTAssertEqual(model.fileName, "Example App 1.0.1.pkg")
        XCTAssertEqual(model.packageName, "Example App 1.0.1")
        XCTAssertEqual(model.categoryID, JamfCategory.noCategory.id)
    }

    // MARK: - canUpload

    func testCannotUploadWithoutAConnection() {
        let model = JamfUploadModel(packageURL: packageURL)

        XCTAssertFalse(model.canUpload)
    }

    func testCanUploadWithAConnectionAndValidFields() {
        XCTAssertTrue(connectedModel().canUpload)
    }

    func testCannotUploadWithAnEmptySecret() {
        let model = JamfUploadModel(packageURL: packageURL)
        model.useConnection(configuration, clientSecret: "")

        XCTAssertFalse(model.canUpload)
    }

    func testCannotUploadWithInvalidFields() {
        let model = connectedModel()
        model.fileName = "Example App.dmg"

        XCTAssertFalse(model.canUpload)
    }

    func testCannotUploadAfterForgettingTheSecret() {
        let model = connectedModel()
        model.forgetSecret()

        XCTAssertFalse(model.canUpload)
    }

    // MARK: - Filename in use

    func testRecordCreatedFailureBlocksThatFilenameUntilItChanges() {
        let model = connectedModel()
        model.applyFailure(
            JamfClientError.packageRecordCreated(packageID: "42", reason: "timed out"),
            cancelled: false,
            fileName: model.fileName
        )

        XCTAssertFalse(model.canUpload)

        model.fileName = "Example App 1.0 retry.pkg"
        XCTAssertTrue(model.canUpload)

        // Padding the original name with spaces doesn't get around the block.
        model.fileName = " Example App 1.0.pkg "
        XCTAssertFalse(model.canUpload)
    }

    func testFailureBeforeARecordExistsDoesNotBlockTheFilename() {
        let model = connectedModel()
        model.applyFailure(
            JamfClientError.authenticationRejected,
            cancelled: false,
            fileName: model.fileName
        )

        XCTAssertTrue(model.canUpload)
        XCTAssertFalse(model.uploadWasCancelled)
        XCTAssertEqual(model.activity.last?.message, "Boxing Day encountered an error.")
        XCTAssertEqual(model.activity.last?.state, .failed)
    }

    // MARK: - Failure messages

    func testCancelledAfterRecordCreatedNamesTheRecord() {
        let outcome = JamfUploadModel.failureOutcome(
            for: JamfClientError.packageRecordCreated(packageID: "6270", reason: "cancelled"),
            cancelled: true
        )

        XCTAssertTrue(outcome.blocksFileName)
        XCTAssertTrue(outcome.message.hasPrefix("Upload cancelled. Jamf Pro package record 6270"))
        XCTAssertFalse(outcome.message.hasSuffix("cancelled"), "The system's own cancellation text shouldn't be appended")
    }

    func testCancelledWhileWaitingForCloudSaysTheFileWasUploaded() {
        let outcome = JamfUploadModel.failureOutcome(
            for: JamfClientError.packageUploadedStatusUnknown(packageID: "7", reason: "cancelled"),
            cancelled: true
        )

        XCTAssertTrue(outcome.blocksFileName)
        XCTAssertTrue(outcome.message.contains("already uploaded as package ID 7"))
    }

    func testCancelledBeforeARecordSaysNothingWasAdded() {
        let outcome = JamfUploadModel.failureOutcome(
            for: CancellationError(),
            cancelled: true
        )

        XCTAssertEqual(
            outcome,
            .init(message: "Upload cancelled. Nothing was added to Jamf Pro.", blocksFileName: false)
        )
    }

    func testCancellationIsRecordedInTheActivityLog() {
        let model = connectedModel()
        model.applyFailure(CancellationError(), cancelled: true, fileName: model.fileName)

        XCTAssertTrue(model.uploadWasCancelled)
        XCTAssertEqual(model.activity.last?.message, "Upload cancelled")
        XCTAssertEqual(model.activity.last?.state, .cancelled)
        XCTAssertEqual(model.uploadError, "Upload cancelled. Nothing was added to Jamf Pro.")
    }

    // MARK: - Activity

    func testEachNewStageFinishesThePreviousOne() {
        let model = connectedModel()
        model.recordActivity(for: .authenticating)
        model.recordActivity(for: .checkingForDuplicate)

        XCTAssertEqual(model.activity.map(\.message), [
            "Authenticating with Jamf Pro",
            "Checking for an existing filename"
        ])
        XCTAssertEqual(model.activity.map(\.state), [.done, .inProgress])
    }

    func testRepeatedStageAddsNoStep() {
        let model = connectedModel()
        model.recordActivity(for: .processingCloud("PENDING"))
        model.recordActivity(for: .processingCloud("PENDING"))

        XCTAssertEqual(model.activity.count, 1)
    }

    func testSuccessFinishesEveryStep() {
        let model = connectedModel()
        model.recordActivity(for: .uploading)
        model.recordSuccess(JamfPackageUploadResult(
            packageID: "1",
            fileName: "Example App 1.0.pkg",
            cloudTransferStatus: "READY"
        ))

        XCTAssertEqual(model.activity.map(\.state), [.done, .done])
        XCTAssertEqual(model.activity.last?.message, "Jamf Pro reported the package ready.")
    }

    func testFailureFinishesEarlierStepsAndMarksItself() {
        let model = connectedModel()
        model.recordActivity(for: .creatingRecord)
        model.applyFailure(CancellationError(), cancelled: true, fileName: model.fileName)

        XCTAssertEqual(model.activity.map(\.state), [.done, .cancelled])
    }

    func testStepIdentitiesAreUnique() {
        let model = connectedModel()
        model.recordActivity(for: .authenticating)
        model.recordActivity(for: .checkingForDuplicate)
        model.applyFailure(JamfClientError.authenticationRejected, cancelled: false, fileName: model.fileName)
        model.recordActivity(for: .authenticating)

        let ids = model.activity.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}

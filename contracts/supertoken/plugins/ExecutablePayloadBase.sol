pragma solidity 0.8.13;

import "./ExecutionHelper.sol";
import "../Base.sol";

abstract contract ExecutablePayloadBase is Base {
    /**
     * @notice this struct stores relevant details for a pending payload execution
     * @param receiver address of receiver where payload executes.
     * @param payload payload to be executed
     * @param isAmountPending if amount to be bridged is pending
     */
    struct PendingExecutionDetails {
        bool isAmountPending;
        uint32 siblingChainSlug;
        address receiver;
        bytes payload;
    }

    ExecutionHelperPlugin public executionHelper__;

    // messageId => PendingExecutionDetails
    mapping(bytes32 => PendingExecutionDetails) public pendingExecutions;

    ////////////////////////////////////////////////////////
    ////////////////////// ERRORS //////////////////////////
    ////////////////////////////////////////////////////////

    error InvalidExecutionRetry();
    error PendingAmount();
    error CannotExecuteOnBridgeContracts();

    // emitted when a execution helper is updated
    event ExecutionHelperUpdated(address executionHelper);

    /**
     * @notice this function is used to update execution helper contract
     * @dev it can only be updated by owner
     * @param executionHelper_ new execution helper address
     */
    function updateExecutionHelper(
        address executionHelper_
    ) external onlyOwner {
        executionHelper__ = ExecutionHelperPlugin(executionHelper_);
        emit ExecutionHelperUpdated(executionHelper_);
    }

    /**
     * @notice this function can be used to retry a payload execution if it was not successful.
     * @param msgId_ The unique identifier of the bridging message.
     */
    function retryPayloadExecution(bytes32 msgId_) external nonReentrant {
        PendingExecutionDetails storage details = pendingExecutions[msgId_];
        if (details.isAmountPending) revert PendingAmount();

        if (details.receiver == address(0)) revert InvalidExecutionRetry();
        bool success = executionHelper__.execute(
            details.receiver,
            details.payload
        );

        if (success) _clearPayload(msgId_);
    }

    /**
     * @notice this function caches the execution payload details if the amount to be bridged
     * is not pending or execution is reverting
     */
    function _cachePayload(
        bytes32 msgId_,
        bool isAmountPending_,
        uint32 siblingChainSlug_,
        address receiver_,
        bytes memory payload_
    ) internal {
        pendingExecutions[msgId_].receiver = receiver_;
        pendingExecutions[msgId_].payload = payload_;
        pendingExecutions[msgId_].siblingChainSlug = siblingChainSlug_;
        pendingExecutions[msgId_].isAmountPending = isAmountPending_;
    }

    /**
     * @notice this function clears the payload details once execution succeeds
     */
    function _clearPayload(bytes32 msgId_) internal {
        pendingExecutions[msgId_].receiver = address(0);
        pendingExecutions[msgId_].payload = bytes("");
        pendingExecutions[msgId_].siblingChainSlug = 0;
        pendingExecutions[msgId_].isAmountPending = false;
    }
}

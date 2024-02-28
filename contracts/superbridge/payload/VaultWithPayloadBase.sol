pragma solidity 0.8.13;

import {Gauge} from "../../common/Gauge.sol";
import {IConnector, IHub} from "../ConnectorPlug.sol";
import {RescueFundsLib} from "../../libraries/RescueFundsLib.sol";
import {SuperBridgePayloadBase} from "./SuperBridgePayloadBase.sol";

abstract contract VaultWithPayloadBase is Gauge, IHub, SuperBridgePayloadBase {
    struct UpdateLimitParams {
        bool isLock;
        address connector;
        uint256 maxLimit;
        uint256 ratePerSecond;
    }

    // connector => receiver => messageId => pendingUnlock
    mapping(address => mapping(address => mapping(bytes32 => uint256)))
        public pendingUnlocks;

    // connector => amount
    mapping(address => uint256) public connectorPendingUnlocks;

    // connector => lockLimitParams
    mapping(address => LimitParams) _lockLimitParams;

    // connector => unlockLimitParams
    mapping(address => LimitParams) _unlockLimitParams;

    error ConnectorUnavailable();
    error ZeroAmount();

    event LimitParamsUpdated(UpdateLimitParams[] updates);
    event TokensDeposited(
        address connector,
        address depositor,
        address receiver,
        uint256 depositAmount,
        bytes32 messageId
    );
    event PendingTokensTransferred(
        address connector,
        address receiver,
        uint256 unlockedAmount,
        uint256 pendingAmount,
        bytes32 messageId
    );
    event TokensPending(
        address connector,
        address receiver,
        uint256 pendingAmount,
        uint256 totalPendingAmount,
        bytes32 messageId
    );
    event TokensUnlocked(
        address connector,
        address receiver,
        uint256 unlockedAmount,
        bytes32 messageId
    );

    function updateLimitParams(
        UpdateLimitParams[] calldata updates_
    ) external onlyOwner {
        for (uint256 i; i < updates_.length; i++) {
            if (updates_[i].isLock) {
                _consumePartLimit(0, _lockLimitParams[updates_[i].connector]); // to keep current limit in sync
                _lockLimitParams[updates_[i].connector].maxLimit = updates_[i]
                    .maxLimit;
                _lockLimitParams[updates_[i].connector]
                    .ratePerSecond = updates_[i].ratePerSecond;
            } else {
                _consumePartLimit(0, _unlockLimitParams[updates_[i].connector]); // to keep current limit in sync
                _unlockLimitParams[updates_[i].connector].maxLimit = updates_[i]
                    .maxLimit;
                _unlockLimitParams[updates_[i].connector]
                    .ratePerSecond = updates_[i].ratePerSecond;
            }
        }

        emit LimitParamsUpdated(updates_);
    }

    function _receiveTokens(
        uint256 amount_
    ) internal virtual returns (uint256 fees);

    function depositToAppChain(
        address receiver_,
        uint256 amount_,
        uint256 msgGasLimit_,
        address connector_,
        bytes calldata execPayload_
    ) external payable {
        if (amount_ == 0) revert ZeroAmount();

        if (_lockLimitParams[connector_].maxLimit == 0)
            revert ConnectorUnavailable();

        _consumeFullLimit(amount_, _lockLimitParams[connector_]); // reverts on limit hit

        uint256 fees = _receiveTokens(amount_);

        bytes32 messageId = IConnector(connector_).getMessageId();
        bytes32 returnedMessageId = IConnector(connector_).outbound{
            value: fees
        }(
            msgGasLimit_,
            abi.encode(receiver_, amount_, messageId, execPayload_)
        );
        if (returnedMessageId != messageId) revert MessageIdMisMatched();

        emit TokensDeposited(
            connector_,
            msg.sender,
            receiver_,
            amount_,
            messageId
        );
    }

    function _sendTokens(address receiver_, uint256 amount_) internal virtual;

    function unlockPendingFor(
        address receiver_,
        address connector_,
        bytes32 messageId_
    ) external {
        if (_unlockLimitParams[connector_].maxLimit == 0)
            revert ConnectorUnavailable();

        uint256 pendingUnlock = pendingUnlocks[connector_][receiver_][
            messageId_
        ];
        (uint256 consumedAmount, uint256 pendingAmount) = _consumePartLimit(
            pendingUnlock,
            _unlockLimitParams[connector_]
        );

        pendingUnlocks[connector_][receiver_][messageId_] = pendingAmount;
        connectorPendingUnlocks[connector_] -= consumedAmount;

        _sendTokens(receiver_, consumedAmount);

        address receiver = pendingExecutions[messageId_].receiver;
        if (pendingAmount == 0 && receiver != address(0)) {
            if (receiver_ != receiver) revert InvalidReceiver();

            address connector = pendingExecutions[messageId_].connector;
            if (connector != connector_) revert InvalidConnector();

            // execute
            pendingExecutions[messageId_].isAmountPending = false;
            bool success = executionHelper__.execute(
                receiver_,
                pendingExecutions[messageId_].payload
            );
            if (success) _clearPayload(messageId_);
        }

        emit PendingTokensTransferred(
            connector_,
            receiver_,
            consumedAmount,
            pendingAmount,
            messageId_
        );
    }

    // receive inbound assuming connector called
    function receiveInbound(bytes memory payload_) external override {
        if (_unlockLimitParams[msg.sender].maxLimit == 0)
            revert ConnectorUnavailable();

        (
            address receiver,
            uint256 unlockAmount,
            bytes32 messageId,
            bytes memory execPayload
        ) = abi.decode(payload_, (address, uint256, bytes32, bytes));

        (uint256 consumedAmount, uint256 pendingAmount) = _consumePartLimit(
            unlockAmount,
            _unlockLimitParams[msg.sender]
        );

        _sendTokens(receiver, consumedAmount);

        if (pendingAmount > 0) {
            // add instead of overwrite to handle case where already pending amount is left
            pendingUnlocks[msg.sender][receiver][messageId] = pendingAmount;
            connectorPendingUnlocks[msg.sender] += pendingAmount;

            if (execPayload.length > 0)
                _cachePayload(
                    messageId,
                    true,
                    msg.sender,
                    receiver,
                    execPayload
                );

            emit TokensPending(
                msg.sender,
                receiver,
                pendingAmount,
                pendingUnlocks[msg.sender][receiver][messageId],
                messageId
            );
        } else if (execPayload.length > 0) {
            // execute
            bool success = executionHelper__.execute(receiver, execPayload);

            if (!success)
                _cachePayload(
                    messageId,
                    false,
                    msg.sender,
                    receiver,
                    execPayload
                );
        }

        emit TokensUnlocked(msg.sender, receiver, consumedAmount, messageId);
    }

    function getMinFees(
        address connector_,
        uint256 msgGasLimit_
    ) external view returns (uint256 totalFees) {
        return IConnector(connector_).getMinFees(msgGasLimit_);
    }

    function getCurrentLockLimit(
        address connector_
    ) external view returns (uint256) {
        return _getCurrentLimit(_lockLimitParams[connector_]);
    }

    function getCurrentUnlockLimit(
        address connector_
    ) external view returns (uint256) {
        return _getCurrentLimit(_unlockLimitParams[connector_]);
    }

    function getLockLimitParams(
        address connector_
    ) external view returns (LimitParams memory) {
        return _lockLimitParams[connector_];
    }

    function getUnlockLimitParams(
        address connector_
    ) external view returns (LimitParams memory) {
        return _unlockLimitParams[connector_];
    }

    /**
     * @notice Rescues funds from the contract if they are locked by mistake.
     * @param token_ The address of the token contract.
     * @param rescueTo_ The address where rescued tokens need to be sent.
     * @param amount_ The amount of tokens to be rescued.
     */
    function rescueFunds(
        address token_,
        address rescueTo_,
        uint256 amount_
    ) external onlyOwner {
        RescueFundsLib.rescueFunds(token_, rescueTo_, amount_);
    }
}

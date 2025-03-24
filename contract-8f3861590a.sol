// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title ERC1155Escrow
 * @notice ERC1155 토큰 거래를 위한 간단한 에스크로 컨트랙트 (양측 모두 Confirm 필요)
 *         - confirmFinalize()를 한 사람이 눌렀을 때, 상대방이 이미 confirm한 상태라면 즉시 finalize
 *         - 그렇지 않다면 두 번째 사람이 confirm 시 finalize
 */
contract ERC1155Escrow is Context, ReentrancyGuard {
    struct EscrowDeal {
        address seller;       // 판매자
        address buyer;        // 구매자
        address nftAddress;   // 거래할 ERC1155 컨트랙트 주소
        uint256 tokenId;      // 거래할 토큰 ID
        uint256 amount;       // 거래할 토큰 수량
        uint256 price;        // 토큰 총 가격 (ETH)
        bool isActive;        // 에스크로 진행 중인지
        bool isFunded;        // 구매자 자금이 예치되었는지
        bool sellerConfirmed; // 판매자 확정 의사
        bool buyerConfirmed;  // 구매자 확정 의사
    }

    mapping(uint256 => EscrowDeal) public escrows;
    uint256 public nextEscrowId;

    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed seller,
        address indexed buyer,
        address nftAddress,
        uint256 tokenId,
        uint256 amount,
        uint256 price
    );

    event EscrowFunded(uint256 indexed escrowId, address indexed buyer, uint256 amount);
    event EscrowConfirmed(uint256 indexed escrowId, address indexed confirmer);
    event EscrowFinalized(uint256 indexed escrowId);
    event EscrowCanceled(uint256 indexed escrowId);

    /**
     * @notice 에스크로 생성(판매자가 호출)
     * @param _buyer 구매자 주소
     * @param _nftAddress ERC1155 토큰 컨트랙트 주소
     * @param _tokenId 토큰 ID
     * @param _amount 거래할 수량
     * @param _price 총 거래 금액(ETH)
     */
    function createEscrow(
        address _buyer,
        address _nftAddress,
        uint256 _tokenId,
        uint256 _amount,
        uint256 _price
    ) external nonReentrant returns (uint256) {
        require(_price > 0, "Price must be > 0");
        require(_amount > 0, "Amount must be > 0");
        require(_buyer != address(0), "Buyer cannot be zero address");

        uint256 escrowId = nextEscrowId;
        nextEscrowId++;

        escrows[escrowId] = EscrowDeal({
            seller: _msgSender(),
            buyer: _buyer,
            nftAddress: _nftAddress,
            tokenId: _tokenId,
            amount: _amount,
            price: _price,
            isActive: true,
            isFunded: false,
            sellerConfirmed: false,
            buyerConfirmed: false
        });

        // 판매자가 토큰을 에스크로로 전송(사전에 setApprovalForAll 필요)
        IERC1155(_nftAddress).safeTransferFrom(
            _msgSender(),
            address(this),
            _tokenId,
            _amount,
            ""
        );

        emit EscrowCreated(
            escrowId,
            _msgSender(),
            _buyer,
            _nftAddress,
            _tokenId,
            _amount,
            _price
        );

        return escrowId;
    }

    /**
     * @notice 구매자가 자금을 에스크로에 예치
     * @param _escrowId 에스크로 ID
     */
    function fundEscrow(uint256 _escrowId) external payable nonReentrant {
        EscrowDeal storage deal = escrows[_escrowId];
        require(deal.isActive, "Escrow not active");
        require(!_isCompleted(deal), "Escrow already completed");
        require(_msgSender() == deal.buyer, "Only buyer can fund escrow");
        require(!deal.isFunded, "Already funded");
        require(msg.value == deal.price, "Invalid ETH amount");

        deal.isFunded = true;
        emit EscrowFunded(_escrowId, _msgSender(), msg.value);
    }

    /**
     * @notice 거래 확정 의사 표시 (양측 모두가 호출해야 최종 finalize 가능)
     *         단, 한쪽이 이미 누른 상태라면 이 함수 내에서 즉시 finalize 처리
     * @param _escrowId 에스크로 ID
     */
    function confirmFinalize(uint256 _escrowId) external nonReentrant {
        EscrowDeal storage deal = escrows[_escrowId];
        require(deal.isActive, "Escrow not active");
        require(!_isCompleted(deal), "Escrow already completed");

        // 판매자 또는 구매자만 가능
        if (_msgSender() == deal.seller) {
            require(!deal.sellerConfirmed, "Seller already confirmed");
            deal.sellerConfirmed = true;
        } else if (_msgSender() == deal.buyer) {
            require(!deal.buyerConfirmed, "Buyer already confirmed");
            deal.buyerConfirmed = true;
        } else {
            revert("Only seller or buyer can confirm");
        }

        emit EscrowConfirmed(_escrowId, _msgSender());

        // 만약 이미 양측 모두 Confirm 했고, 자금이 예치되었다면 자동 finalize
        if (deal.sellerConfirmed && deal.buyerConfirmed && deal.isFunded) {
            _finalizeEscrow(_escrowId);
        }
    }

    /**
     * @notice 실제 거래를 최종 확정하는 외부 함수
     *         confirmFinalize에서 자동으로 finalize되지 않았다면, 이 함수를 직접 호출할 수도 있음.
     * @param _escrowId 에스크로 ID
     */
    function finalizeEscrow(uint256 _escrowId) external nonReentrant {
        EscrowDeal storage deal = escrows[_escrowId];
        require(deal.isActive, "Escrow not active");
        require(deal.isFunded, "Escrow not funded");
        require(deal.sellerConfirmed && deal.buyerConfirmed, "Both parties must confirm");
        // finalize를 누가 호출해도 상관없도록 설정(프로젝트 상황에 따라 제한 가능)
        require(
            _msgSender() == deal.seller || _msgSender() == deal.buyer,
            "Only seller or buyer can finalize"
        );

        _finalizeEscrow(_escrowId);
    }

    /**
     * @dev 내부에서 에스크로를 실제로 종료해주는 로직
     */
    function _finalizeEscrow(uint256 _escrowId) internal {
        EscrowDeal storage deal = escrows[_escrowId];

        // 에스크로를 종료 처리
        deal.isActive = false;

        // 토큰 -> 구매자
        IERC1155(deal.nftAddress).safeTransferFrom(
            address(this),
            deal.buyer,
            deal.tokenId,
            deal.amount,
            ""
        );

        // 이더(ETH) -> 판매자
        (bool success, ) = payable(deal.seller).call{value: deal.price}("");
        require(success, "Transfer failed");

        emit EscrowFinalized(_escrowId);
    }

    /**
     * @notice 거래 취소
     * @dev 아직 완료되지 않은 거래만 취소 가능
     * @param _escrowId 에스크로 ID
     */
    function cancelEscrow(uint256 _escrowId) external nonReentrant {
        EscrowDeal storage deal = escrows[_escrowId];
        require(deal.isActive, "Escrow not active");
        // 판매자 또는 구매자만 취소 가능
        require(
            _msgSender() == deal.seller || _msgSender() == deal.buyer,
            "Only seller or buyer can cancel"
        );

        // 구매자 자금이 이미 예치됐다면 되돌려줌 (단순 예시)
        if (deal.isFunded) {
            (bool refundSuccess, ) = payable(deal.buyer).call{value: deal.price}("");
            require(refundSuccess, "Refund to buyer failed");
        }

        // 토큰은 판매자에게 되돌려주기
        IERC1155(deal.nftAddress).safeTransferFrom(
            address(this),
            deal.seller,
            deal.tokenId,
            deal.amount,
            ""
        );

        deal.isActive = false;
        emit EscrowCanceled(_escrowId);
    }

    // ERC1155 수신 인터페이스
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    /**
     * @dev 에스크로가 완료되었는지(비활성화) 여부 판단
     */
    function _isCompleted(EscrowDeal memory deal) internal pure returns (bool) {
        return !deal.isActive;
    }
}

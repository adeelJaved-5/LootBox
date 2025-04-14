// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "./Utils.sol";
import {Ownable} from "./Utils.sol";
import {MerkleProof} from "./Utils.sol";
import {IERC1155Receiver} from "./Utils.sol";

contract LootBox is ERC1155, Ownable {
    uint256 public maxSupply = 5000;
    uint256 public totalMinted;

    uint256[] public tokenIdPool = [1, 2, 3, 4, 5, 6, 7];
    uint256[] public tokenProbabilities = [32, 32, 15, 10, 6, 4, 1];
    uint256 private constant CALLBACK_GAS_LIMIT = 50000;

    enum MintType {
        Public,
        WL1,
        WL2
    }

    struct MintConfig {
        uint256 price;
        uint256 startTime;
        uint256 endTime;
        uint8 freeMintsAllowed;
        bytes32 merkleRoot;
    }

    mapping(MintType => MintConfig) public mintConfigs;
    mapping(address => mapping(MintType => uint256)) public userMints;
    mapping(uint256 => uint256) public tokenIdSupply;

    event URIUpdated(string newURI);
    event Minted(
        address indexed minter,
        uint256 indexed tokenId,
        MintType indexed mintType
    );
    event MintConfigUpdated(
        MintType indexed mintType,
        uint256 price,
        uint256 startTime,
        uint256 endTime,
        bytes32 merkleRoot,
        uint8 freeMints
    );

    // Reentrancy guard implementation
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor() ERC1155("BitBeta Skin", "LB", "https://api.ipfs.metadata/") {}

    function updateMintConfig(
        MintType mintType,
        uint256 price,
        uint256 startTime,
        uint256 endTime,
        bytes32 merkleRoot,
        uint8 freeMints
    ) external onlyOwner {
        require(startTime < endTime, "Invalid mint time");
        mintConfigs[mintType] = MintConfig(
            price,
            startTime,
            endTime,
            freeMints,
            merkleRoot
        );
        emit MintConfigUpdated(
            mintType,
            price,
            startTime,
            endTime,
            merkleRoot,
            freeMints
        );
    }

    function setURI(string memory newURI) external onlyOwner {
        _setURI(newURI); // Calls the internal ERC1155 _setURI function
        emit URIUpdated(newURI);
    }

    function setMaxSupply(uint256 newSupply) external onlyOwner {
        require(newSupply >= totalMinted, "New supply < already minted");
        maxSupply = newSupply;
    }

    function withdraw() external onlyOwner {
        (bool success, ) = owner().call{value: address(this).balance}("");
        require(success, "Transfer failed.");
    }

    function mintPublic(uint256 quantity) external payable nonReentrant {
        _mintTokens(quantity, MintType.Public, new bytes32[](0));
    }

    function mintWL1(
        uint256 quantity,
        bytes32[] calldata proof
    ) external payable nonReentrant {
        _mintTokens(quantity, MintType.WL1, proof);
    }

    function mintWL2(
        uint256 quantity,
        bytes32[] calldata proof
    ) external payable nonReentrant {
        // Added nonReentrant
        _mintTokens(quantity, MintType.WL2, proof);
    }

    function _mintTokens(
        uint256 quantity,
        MintType mintType,
        bytes32[] memory proof
    ) internal nonReentrant {
        // Added internal nonReentrant for extra protection
        MintConfig memory config = mintConfigs[mintType];
        require(
            block.timestamp >= config.startTime &&
                block.timestamp <= config.endTime,
            "Mint not active"
        );
        require(totalMinted + quantity <= maxSupply, "Max supply reached");

        uint256 paidQuantity = quantity;
        uint256 alreadyClaimed = userMints[msg.sender][mintType];

        if (mintType != MintType.Public) {
            bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
            require(
                MerkleProof.verify(proof, config.merkleRoot, leaf),
                "Not whitelisted"
            );

            if (alreadyClaimed < config.freeMintsAllowed) {
                uint256 freeRemaining = config.freeMintsAllowed -
                    alreadyClaimed;
                uint256 freeToUse = quantity > freeRemaining
                    ? freeRemaining
                    : quantity;
                paidQuantity -= freeToUse;
                userMints[msg.sender][mintType] += quantity;
            } else {
                userMints[msg.sender][mintType] += quantity;
            }
        }

        require(msg.value == paidQuantity * config.price, "Incorrect ETH sent");

        for (uint256 i = 0; i < quantity; i++) {
            uint256 tokenId = _getRandomTokenId();
            tokenIdSupply[tokenId]++;
            totalMinted++;
            emit Minted(msg.sender, tokenId, mintType);
            _mint(msg.sender, tokenId, 1, abi.encode(CALLBACK_GAS_LIMIT));
        }
    }

    function _getRandomTokenId() internal view returns (uint256) {
        // Ensure blockhashes are available
        require(block.number - 5 > 0, "Insufficient block history");

        uint256 rand = uint256(
            keccak256(
                abi.encodePacked(
                    msg.sender,
                    totalMinted,
                    blockhash(block.number - 1),
                    blockhash(block.number - 3),
                    blockhash(block.number - 5),
                    block.prevrandao,
                    address(this).balance
                )
            )
        ) % 100;

        uint256 cumulative = 0;
        for (uint256 i = 0; i < tokenProbabilities.length; i++) {
            cumulative += tokenProbabilities[i];
            if (rand < cumulative) {
                return tokenIdPool[i];
            }
        }
        return tokenIdPool[tokenIdPool.length - 1];
    }

    // Override the transfer acceptance check with gas limiting
    function _doSafeTransferAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256 id,
        uint256 value,
        bytes memory data
    ) internal override {
        uint256 gasLimit = abi.decode(data, (uint256));

        if (to.code.length > 0) {
            try
                IERC1155Receiver(to).onERC1155Received{gas: gasLimit}(
                    operator,
                    from,
                    id,
                    value,
                    data
                )
            returns (bytes4 response) {
                if (response != IERC1155Receiver.onERC1155Received.selector) {
                    revert("ERC1155: ERC1155Receiver rejected tokens");
                }
            } catch {
                revert("ERC1155: transfer to non ERC1155Receiver implementer");
            }
        }
    }
}

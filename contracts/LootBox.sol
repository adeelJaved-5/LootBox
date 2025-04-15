// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "./Utils.sol";
import {Ownable} from "./Utils.sol";
import {MerkleProof} from "./Utils.sol";
import {IERC1155Receiver} from "./Utils.sol";

contract LootBox is ERC1155, Ownable {
    uint256 public maxSupply = 5000;
    uint256 public totalMinted;
    uint256 private _entropyNonce;

    uint256[] public tokenIdPool = [1, 2, 3, 4, 5, 6, 7];
    uint256[] public tokenProbabilities = [32, 32, 15, 10, 6, 4, 1];

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

    function _mint(
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) internal override {
        super._mint(to, id, amount, data);
        emit TransferSingle(_msgSender(), address(0), to, id, amount);
    }

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
        _setURI(newURI);
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
        _mintTokens(quantity, MintType.WL2, proof);
    }

    function _mintTokens(
        uint256 quantity,
        MintType mintType,
        bytes32[] memory proof
    ) internal nonReentrant {
        require(quantity > 0, "Must mint at least 1 NFT");
        require(totalMinted + quantity <= maxSupply, "Max supply reached");

        MintConfig memory config = mintConfigs[mintType];
        require(
            block.timestamp >= config.startTime &&
                block.timestamp <= config.endTime,
            "Mint not active"
        );

        uint256 paidQuantity = quantity;
        uint256 freeQuantity = 0;

        if (mintType != MintType.Public) {
            bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
            require(
                MerkleProof.verify(proof, config.merkleRoot, leaf),
                "Not whitelisted"
            );

            uint256 freeMintsUsed = userMints[msg.sender][mintType];
            if (freeMintsUsed < config.freeMintsAllowed) {
                uint256 freeRemaining = config.freeMintsAllowed - freeMintsUsed;
                freeQuantity = quantity > freeRemaining
                    ? freeRemaining
                    : quantity;
                paidQuantity = quantity - freeQuantity;
                // Only update free mints count
                userMints[msg.sender][mintType] += freeQuantity;
            }
        }

        require(msg.value == paidQuantity * config.price, "Incorrect ETH sent");

        for (uint256 i = 0; i < quantity; i++) {
            uint256 tokenId = _getRandomTokenId();
            tokenIdSupply[tokenId]++;
            totalMinted++;
            emit Minted(msg.sender, tokenId, mintType);
            _mint(msg.sender, tokenId, 1, ""); // Empty data prevents callbacks
        }
    }

    function _getRandomTokenId() internal returns (uint256) {
        // Increment nonce for each generation
        _entropyNonce++;

        uint256 rand = uint256(
            keccak256(
                abi.encodePacked(
                    msg.sender,
                    tx.gasprice,
                    block.timestamp,
                    blockhash(block.number),
                    totalMinted
                )
            )
        ) % 100;

        uint256 cumulative;
        for (uint256 i = 0; i < tokenProbabilities.length; i++) {
            cumulative += tokenProbabilities[i];
            if (rand < cumulative) {
                return tokenIdPool[i];
            }
        }
        return tokenIdPool[tokenIdPool.length - 1];
    }
}

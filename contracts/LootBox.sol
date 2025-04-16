// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "./Utils.sol";
import {Ownable} from "./Utils.sol";
import {MerkleProof} from "./Utils.sol";
import {IERC1155Receiver} from "./Utils.sol";

contract LootBox is ERC1155, Ownable {
    uint256 private _entropyNonce;

    uint256[] public tokenIdPool = [1, 2, 3, 4, 5, 6, 7];
    uint256[] public tokenProbabilities = [32, 32, 15, 10, 4, 6, 1];

    enum MintType {
        WL1,
        WL2,
        WL3
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
    event OddsUpdated(uint256[] newProbabilities);

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

    function withdraw() external onlyOwner {
        (bool success, ) = owner().call{value: address(this).balance}("");
        require(success, "Transfer failed.");
    }

    function updateOdds(
        uint256[] calldata newProbabilities
    ) external onlyOwner {
        uint256 len = newProbabilities.length;
        require(len == tokenProbabilities.length, "Length mismatch");

        uint256 sum;
        for (uint256 i = 0; i < len; ) {
            require(newProbabilities[i] > 0, "Probability cannot be zero");
            sum += newProbabilities[i];
            unchecked {
                ++i;
            }
        }
        require(sum == 100, "Probabilities must sum to 100");
        tokenProbabilities = newProbabilities;
        emit OddsUpdated(newProbabilities);
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

    function mintWL3(
        uint256 quantity,
        bytes32[] calldata proof
    ) external payable nonReentrant {
        _mintTokens(quantity, MintType.WL3, proof);
    }

    function _mintTokens(
        uint256 quantity,
        MintType mintType,
        bytes32[] memory proof
    ) internal nonReentrant {
        require(quantity > 0, "Must mint at least 1 NFT");

        MintConfig memory config = mintConfigs[mintType];
        require(
            block.timestamp >= config.startTime &&
                block.timestamp <= config.endTime,
            "Mint not active"
        );
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        require(
            MerkleProof.verify(proof, config.merkleRoot, leaf),
            "Not whitelisted"
        );

        // Free vs paid calculation
        uint256 freeMintsUsed = userMints[msg.sender][mintType];
        uint256 freeRemaining = config.freeMintsAllowed > freeMintsUsed
            ? config.freeMintsAllowed - freeMintsUsed
            : 0;
        uint256 freeQuantity = quantity > freeRemaining
            ? freeRemaining
            : quantity;
        uint256 paidQuantity = quantity - freeQuantity;

        if (freeQuantity > 0) {
            userMints[msg.sender][mintType] += freeQuantity;
        }

        require(msg.value == paidQuantity * config.price, "Incorrect ETH sent");
        for (uint256 i = 0; i < quantity; i++) {
            uint256 tokenId = _getRandomTokenId();
            tokenIdSupply[tokenId]++;
            emit Minted(msg.sender, tokenId, mintType);
            _mint(msg.sender, tokenId, 1, "");
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
                    blockhash(block.number)
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

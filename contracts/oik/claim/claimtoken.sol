// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "solmate/src/utils/SafeTransferLib.sol";
import "solmate/src/tokens/ERC20.sol";

/**
 * @title ClaimToken
 * @dev Space Nation claim tokens
 * @author @SpaceNation
 * @notice Space Nation claim tokens
 */
contract ClaimToken is Ownable, ReentrancyGuard {
    using ECDSA for bytes32;
    //The expiration time of the signature. If set to 0, it indicates that the signature user has expired.
    uint64 private expireTime = 300;
    uint256 private thresholds;
    bool private checkthresholds;
    //The wallet address for storing tokens.
    mapping(uint64 => address) public payers;
    mapping(uint64 => address) public tokens;
    mapping(uint64 => bool) private sigvalue;
    mapping(address => uint256) private claimed;
    mapping(address => bool) private signers;
    event Claim(
        address indexed claimer,
        uint64 indexed signId,
        address token,
        uint256 amount
    );

    constructor(address[] memory _signers, uint64 _thresholds) {
        address signer;
        for (uint256 i = 0; i < _signers.length; i++) {
            signer = _signers[i];
            signers[signer] = true;
        }
        thresholds = _thresholds;
    }

    /**
     * @notice Only the contract owner address can configure the index value of the wallet address.
     * @param addrs. Array of token wallet addresses.
     * @param indexs. The index value corresponding to each address.
     */
    function setPayers(address[] memory addrs, uint64[] memory indexs)
        external
        onlyOwner
    {
        uint256 len = addrs.length;
        require(indexs.length == len, "INVALID_ARRAY");
        uint64 index;
        address addr;
        for (uint256 i = 0; i < len; i++) {
            index = indexs[i];
            addr = addrs[i];
            payers[index] = addr;
        }
    }

    /**
     * @notice Only the contract owner address can configure the index value of the token address.
     * @param addrs. Array of token wallet addresses.
     * @param indexs. The index value corresponding to each address.
     */
    function setTokens(address[] memory addrs, uint64[] memory indexs)
        external
        onlyOwner
    {
        uint256 len = addrs.length;
        require(indexs.length == len, "INVALID_ARRAY");
        uint64 index;
        address addr;
        for (uint256 i = 0; i < len; i++) {
            index = indexs[i];
            addr = addrs[i];
            tokens[index] = addr;
        }
    }

    /**
     * @notice Only the contract owner can airdrop tokens
     * @param players. Array of airdrop addresses.
     * @param amounts. Array of airdrop amounts corresponding to each address.
     * @param pindex. Index values of airdrop token wallet addresses in this contract.
     * @param tindex. Index value of the token address in this contract.
     */
    function transfer(
        address[] memory players,
        uint256[] memory amounts,
        uint32 pindex,
        uint32 tindex
    ) external onlyOwner nonReentrant {
        uint256 len = players.length;
        require(amounts.length == len, "INVALID_ARRAY");
        uint256 amount;
        address player;
        for (uint256 i = 0; i < len; i++) {
            amount = amounts[i];
            player = players[i];

            SafeTransferLib.safeTransferFrom(
                ERC20(tokens[tindex]),
                payers[pindex],
                player,
                amount
            );
        }
    }

    /**
     * @notice Users claim tokens through a valid signature.
     * @param amount. Amount of tokens claimed by the user.
     * @param uuid. Random value for this signature must not be duplicated.
     * @param signId. Signature ID for use in off-chain systems.
     * @param pindex. Index values of airdrop token wallet addresses in this contract.
     * @param tindex. Index value of the token address in this contract.
     * @param sig. Signature generated off-chain based on the user's claim information.
     */
    function claim(
        uint256 amount,
        uint256 maxamount,
        uint64 timestamp,
        uint64 uuid,
        uint64 signId,
        uint32 pindex,
        uint32 tindex,
        bytes memory sig
    ) external nonReentrant {
        if (checkthresholds && amount > thresholds) {
            revert();
        }
        assertValidCosign(
            amount,
            maxamount,
            timestamp,
            uuid,
            signId,
            pindex,
            tindex,
            sig
        );
        SafeTransferLib.safeTransferFrom(
            ERC20(tokens[tindex]),
            payers[pindex],
            _msgSender(),
            amount
        );
        emit Claim(_msgSender(), signId, tokens[tindex], amount);
    }

    /**
     * @notice Users claim tokens through some signatures.
     * @param amount. Amount of tokens claimed by the user.
     * @param uuids. Random value for this signature must not be duplicated.
     * @param signId. Signature ID for use in off-chain systems.
     * @param pindex. Index values of airdrop token wallet addresses in this contract.
     * @param tindex. Index value of the token address in this contract.
     * @param sigs. Signatures generated off-chain based on the user's claim information.
     */
    function bigclaim(
        uint256 amount,
        uint256 maxamount,
        uint64[] memory timestamps,
        uint64[] memory uuids,
        uint64 signId,
        uint32 pindex,
        uint32 tindex,
        bytes[] memory sigs
    ) external nonReentrant {
        if (amount < thresholds) {
            revert();
        }

        uint256 len = uuids.length;
        require(len > 1, "AT_LEAST_TWO_SIGNATURES");
        require(sigs.length == len, "INVALID_ARRAY");
        require(timestamps.length == len, "INVALID_ARRAY");
        uint64 uuid;
        bytes memory sig;
        uint64 timestamp;
        for (uint256 i = 0; i < len; i++) {
            uuid = uuids[i];
            sig = sigs[i];
            timestamp = timestamps[i];
            assertValidCosign(
                amount,
                maxamount,
                timestamp,
                uuid,
                signId,
                pindex,
                tindex,
                sig
            );
        }

        SafeTransferLib.safeTransferFrom(
            ERC20(tokens[tindex]),
            payers[pindex],
            _msgSender(),
            amount
        );
        emit Claim(_msgSender(), signId, tokens[tindex], amount);
    }

    /**
     * @notice Returns chain id.
     */
    function _chainID() private view returns (uint64) {
        uint64 chainID;
        assembly {
            chainID := chainid()
        }
        return chainID;
    }

    function assertValidCosign(
        uint256 amount,
        uint256 maxamount,
        uint64 timestamp,
        uint64 uuid,
        uint64 signId,
        uint32 pindex,
        uint32 tindex,
        bytes memory sig
    ) private returns (bool) {
        if (timestamp != 0) {
            require((expireTime + timestamp >= block.timestamp), "HAS_EXPIRED");
        }
        if (maxamount != 0) {
            require(
                claimed[_msgSender()] + amount <= maxamount,
                "EXCEED_MAX_CLAIM_AMOUNT"
            );
        }
        require((!sigvalue[uuid]), "HAS_USED");
        bytes32 hash = keccak256(
            abi.encodePacked(
                amount,
                maxamount,
                timestamp,
                uuid,
                signId,
                _chainID(),
                pindex,
                tindex,
                _msgSender(),
                address(this)
            )
        );
        require(matchSigner(hash, sig), "INVALID_SIGNATURE");
        claimed[_msgSender()] += amount;
        sigvalue[uuid] = true;
        return true;
    }

    function matchSigner(bytes32 hash, bytes memory signature)
        private
        view
        returns (bool)
    {
        address _signer = hash.toEthSignedMessageHash().recover(signature);
        return signers[_signer];
    }

    /**
     * @notice Sets signer.
     */
    function setthresholds(uint256 _thresholds, bool flag) external onlyOwner {
        thresholds = _thresholds;
        checkthresholds = flag;
    }

    /**
     * @notice Sets signer.
     */
    function setSigner(address cosigner, bool flag) external onlyOwner {
        signers[cosigner] = flag;
    }

    /**
     * @notice Sets expiry in seconds. This timestamp specifies how long a signature from cosigner is valid for.
     */
    function setTimestampExpirySeconds(uint64 expiry) external onlyOwner {
        expireTime = expiry;
    }

    function renounceOwnership() public view override onlyOwner {
        revert("CLOSED");
    }

    /**
     * @notice Refund of tokens mistakenly transferred.
     */
    function withdrawsToken(uint32 tindex, address to) external onlyOwner {
        address token = tokens[tindex];
        uint256 balance = ERC20(token).balanceOf(address(this));
        SafeTransferLib.safeTransfer(ERC20(token), to, balance);
    }
}

// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface NFTBurn {
    function burn(uint256 tokenId) external;
}

contract stakeShip is Ownable, ReentrancyGuard {
    using ECDSA for bytes32;
    // The program address for implementing black and redeem.
    address miner;
    //The minimum staking period is 3 days, and the maximum is 365 days.
    uint64 floorlimit = 3 days;
    uint64 ceillimit = 365 days;
    // The default expiration time for signatures is 300 seconds (5 minutes).
    uint32 private expireTime = 300;
    uint32 limitIdLen = 50;
    //The maximum duration of blacking is 90 days.
    uint64 constant BLACKCEIL = 90 days;

    // The global switch that controls the entire system. When activated, all staked assets can be withdrawn regardless of the normal staking conditions.
    uint256 globalswitch;
    // The mask of the lower 160 bits for addresses.
    uint256 private constant _BITMASK_ADDRESS = (1 << 160) - 1;
    // The bit position of `startTimestamp` in packed ownership.
    uint256 private constant _BITPOS_START_TIMESTAMP = 160;

    // The signature address.
    address private _cosigner = 0xDa801D3cCE8626Bd55387554Bb3BE500681Cb49C;
    // The address-specific switch. When this is turned on, the associated address can withdraw their staked assets regardless of the normal conditions.
    mapping(address => uint256) addrswitch;
    // The switch for a specific NFT ID. When this is enabled, only the staking associated with that particular NFT ID can be directly withdrawn, ignoring normal staking conditions.
    mapping(address => mapping(uint256 => uint256)) nftswitch;
    // The NFT contracts that are supported by the staking contract.
    mapping(address => bool) supportnft;
    // The staking information for specific NFT IDs from the supported NFT contract's Id.
    mapping(address => mapping(uint256 => uint256)) private stakeInfo;
    // The blacking information for specific addresses.
    mapping(address => uint256) blackInfo;
    // The functionality to check if a given signature has already been used before.
    mapping(uint64 => bool) private _sigvalue;

    event UserOp(
        address indexed nft,
        address indexed staker,
        uint256[] nftId,
        uint256 timestamp,
        uint256 types
    );
    event MinerOp(
        address[] staker,
        uint256 indexed timestamp,
        uint256 indexed types
    );

    event Burn(uint64 indexed signId);
    error InBannedStatus();
    error UnableToUnstake();
    error InvalidStakingTime();
    error NotSupportedNFT();
    error InvalidExtendTime();
    error ExceedBlackCeil();

    constructor(address _miner, address[] memory nfts) {
        require(_miner != address(0), "Invalid address");
        miner = _miner;
        supportNFT(nfts, true);
    }

    modifier onlyMiner() {
        require(miner == _msgSender(), "Ownable: caller is not the miner");
        _;
    }

    /**
     * @notice Only the contract owner can change the miner address, which must be a valid address
     * @param newminer.
     */
    function updateMiner(address newminer) external onlyOwner {
        require(newminer != address(0), "Invalid address");
        miner = newminer;
    }

    /**
     * @notice Only the contract owner can update the expiration time for signatures
     * @param expiry.
     */
    function setTimestampExpirySeconds(uint32 expiry) external onlyOwner {
        expireTime = expiry;
    }

    /**
     * @notice Only the contract owner can update the limitIdLen of batch-staking
     */
    function setLimitLen(uint32 _limitIdLen) external onlyOwner {
        limitIdLen = _limitIdLen;
    }

    /**
     * @notice Only the contract owner can update the list of NFT contracts that are supported or unsupported by the staking contract.
     * @param nfts.
     * @param status.
     */
    function setSupportNFT(address[] memory nfts, bool status)
        external
        onlyOwner
    {
        supportNFT(nfts, status);
    }

    function supportNFT(address[] memory nfts, bool status) private {
        uint256 len = nfts.length;
        address nft;
        for (uint256 index = 0; index < len; index++) {
            nft = nfts[index];
            supportnft[nft] = status;
        }
    }

    /**
     * @notice Only the contract owner can update the minimum and maximum staking period.
     * @param floorts.
     * @param ceilts.
     */
    function updateTsLimit(uint64 floorts, uint64 ceilts) external onlyOwner {
        floorlimit = floorts;
        ceillimit = ceilts;
    }

    /**
     * @notice Only the contract owner can enable the global switch for a duration time.
     * @param duration.
     */
    function setGloSwitch(uint256 duration) external onlyOwner {
        uint256 ts = block.timestamp;
        globalswitch = ts + duration;
    }

    /**
     * @notice Only the contract owner can enable the address-specific switch for a specific address and a set duration.
     * @param addr.
     * @param duration.
     */
    function setAddrSwitch(address addr, uint256 duration) external onlyOwner {
        uint256 ts = block.timestamp;
        addrswitch[addr] = ts + duration;
    }

    /**
     * @notice Only the contract owner can enable the NFTdD-specific switch for a specific NFT contract and a set duration.
     * @param nft.
     * @param nftId.
     * @param duration.
     */
    function setNFTSwitch(
        address nft,
        uint256 nftId,
        uint256 duration
    ) external onlyOwner {
        uint256 ts = block.timestamp;
        nftswitch[nft][nftId] = ts + duration;
    }

    /**
     * @notice Staking requires a supported NFT and a valid timestamp duration between the floor limit and ceiling limit. Meanwhile, the transaction reverts if the sender is on the blacklist, and the blacklist information will be deleted if the sender is not on the blacklist or the blacklist duration has ended.
     * @param nft Staking must specify the NFT contract.
     * @param nftIds Staking must specify the NFTId.
     * @param timestamp Staking must provide a duration.
     */
    function stake(
        address nft,
        uint256[] calldata nftIds,
        uint256 timestamp
    ) external nonReentrant {
        address staker = _msgSender();
        uint256 len = nftIds.length;
        require(len <= limitIdLen, "Exceed maximum length");
        checkts(nft, timestamp, staker);
        uint256 nftId;
        uint256 endts = timestamp + block.timestamp;
        uint256 packdata = _packStakeData(staker, endts);
        for (uint256 index = 0; index < len; index++) {
            nftId = nftIds[index];
            IERC721(nft).safeTransferFrom(staker, address(this), nftId);
            stakeInfo[nft][nftId] = packdata;
        }
        emit UserOp(nft, staker, nftIds, endts, 0);
    }

    /**
     * @notice For unstaking, the sender must be the address that staked the NFTID. They can unstake the NFTID if any switches are enabled for him, or if the maximum staking and blacklist durations have ended. Unstaking will delete the blacklist state for the player.
     * @param nft Staking must specify the NFT contract.
     * @param nftIds Staking must specify the NFTId.
     */
    function unstake(address nft, uint256[] calldata nftIds)
        external
        nonReentrant
    {
        address unstaker = _msgSender();
        uint256 len = nftIds.length;
        require(len <= limitIdLen, "Exceed maximum length");
        uint256 nftId;
        uint256 ts = block.timestamp;
        bool temstatus = globalswitch > ts || addrswitch[unstaker] > ts;
        for (uint256 index = 0; index < len; index++) {
            nftId = nftIds[index];
            stakeDataCheck(unstaker, nft, nftId);
            bool status = temstatus || nftswitch[nft][nftId] > ts;
            if (!status) {
                uint256 maxts = stakEndts(nft, unstaker, nftId);
                if (ts > maxts) {
                    delete blackInfo[unstaker];
                } else {
                    revert UnableToUnstake();
                }
            }
            IERC721(nft).safeTransferFrom(address(this), unstaker, nftId);
            delete stakeInfo[nft][nftId];
        }
        emit UserOp(nft, unstaker, nftIds, ts, 2);
    }

    /**
     * @notice For extending a stake, the sender must be the address that staked the NFT ID. They can extend the staking duration for the specific NFT ID. Extending will delete the blacklist state if the sender has been blacklisted but the blacklisted duration has now expired.
     * @param nft Extending must specify the NFT contract.
     * @param nftIds Extending must specify the NFTId.
     * @param timestamp Extending must provide a duration between floorlimit and ceillimit.
     */
    function extend(
        address nft,
        uint256[] calldata nftIds,
        uint64 timestamp
    ) external {
        address staker = _msgSender();
        checkts(nft, timestamp, staker);
        uint256 len = nftIds.length;
        require(len <= limitIdLen, "Exceed maximum length");
        uint256 nftId;
        uint256 ts = block.timestamp;
        for (uint256 index = 0; index < len; index++) {
            nftId = nftIds[index];
            uint256 stakets = stakeDataCheck(staker, nft, nftId);
            uint256 endts = ts > stakets ? ts : stakets;
            endts += timestamp;
            if (endts - ts > ceillimit) {
                endts = ts + ceillimit;
            }
            stakeInfo[nft][nftId] = _packStakeData(staker, endts);
            uint256[] memory tem = new uint256[](1);
            tem[0] = nftId;
            emit UserOp(nft, staker, tem, endts, 1);
        }
    }

    /**
     * @notice Only the Miner can blacklist players who are not already in a blacklisted state, for a maximum duration of BLACKCEIL.
     * @param players The blacking player address.
     * @param timestamp The blacking duration less than BLACKCEIL.
     */
    function black(address[] calldata players, uint256 timestamp)
        external
        onlyMiner
    {
        if (timestamp > BLACKCEIL) {
            revert ExceedBlackCeil();
        }
        address player;
        uint256 len = players.length;
        require(len <= limitIdLen, "Exceed maximum length");
        uint256 endts = timestamp + block.timestamp;
        for (uint256 index = 0; index < len; index++) {
            player = players[index];
            require((blackInfo[player] == 0), "The user has been banned");
            blackInfo[player] = endts;
        }
        emit MinerOp(players, endts, 0);
    }

    /**
     * @notice Only the Miner can reduce the blacklist duration for players.
     * @param players The redeem player address.
     * @param timestamp The redeem duration less than BLACKCEIL.
     */
    function redeem(address[] calldata players, uint256 timestamp)
        external
        onlyMiner
    {
        address player;
        uint256 len = players.length;
        require(len <= limitIdLen, "Exceed maximum length");
        for (uint256 index = 0; index < len; index++) {
            player = players[index];
            uint256 remaingts = blackRemaingSeconds(player);
            if (remaingts <= timestamp) {
                delete blackInfo[player];
            } else {
                blackInfo[player] -= timestamp;
            }
            address[] memory tem = new address[](1);
            tem[0] = player;
            emit MinerOp(tem, blackInfo[player], 1);
        }
    }

    /**
     * @notice Stakers can burn their NFTs based on a valid signed request.
     */
    function disassemble(
        address nft,
        uint32[] calldata nftIds,
        uint64 timestamp,
        uint64 uuid,
        uint64 signId,
        bytes memory sig
    ) external {
        assertValidCosign(nft, nftIds, timestamp, uuid, signId, sig);
        (uint32 nftId, uint256 len, address staker) = (
            0,
            nftIds.length,
            _msgSender()
        );
        if (blackRemaingSeconds(staker) != 0) {
            revert InBannedStatus();
        }
        for (uint256 i = 0; i < len; i++) {
            nftId = nftIds[i];
            stakeDataCheck(staker, nft, nftId);
            NFTBurn(nft).burn(nftId);
        }
        emit Burn(signId);
    }

    function assertValidCosign(
        address nft,
        uint32[] memory nftId,
        uint64 timestamp,
        uint64 uuid,
        uint64 signId,
        bytes memory sig
    ) private returns (bool) {
        uint32 chainID;
        assembly {
            chainID := chainid()
        }
        bytes32 hash = keccak256(
            abi.encodePacked(
                nftId,
                chainID,
                timestamp,
                uuid,
                signId,
                nft,
                _msgSender(),
                address(this)
            )
        );
        require(matchSigner(hash, sig), "Invalid_Signature");
        if (timestamp != 0) {
            require((expireTime + timestamp >= block.timestamp), "HAS_Expired");
        }
        require((!_sigvalue[uuid]), "HAS_USED");
        _sigvalue[uuid] = true;
        return true;
    }

    function matchSigner(bytes32 hash, bytes memory signature)
        private
        view
        returns (bool)
    {
        return _cosigner == hash.toEthSignedMessageHash().recover(signature);
    }

    /**
     * @notice Sets cosigner.
     */
    function setCosigner(address cosigner) external onlyOwner {
        require(cosigner != address(0), "Invalid address");
        _cosigner = cosigner;
    }

    /**
     * @notice Returns the packed data based on the staking address and time duration.
     */
    function _packStakeData(address owner, uint256 ts)
        private
        pure
        returns (uint256 result)
    {
        assembly {
            // Mask `owner` to the lower 160 bits, in case the upper bits somehow aren't clean.
            owner := and(owner, _BITMASK_ADDRESS)
            // `owner | (block.timestamp << _BITPOS_START_TIMESTAMP)`.
            result := or(owner, shl(_BITPOS_START_TIMESTAMP, ts))
        }
    }

    /**
     * @notice Returns the unpacked staking address and time duration from `packed`.
     */
    function _unpackedStakeInfo(uint256 packed)
        private
        pure
        returns (address, uint256)
    {
        return (address(uint160(packed)), packed >> _BITPOS_START_TIMESTAMP);
    }

    /**
     * @notice Validate the NFT address, staking duration, and blacklist state.
     */
    function checkts(
        address nft,
        uint256 ts,
        address staker
    ) internal {
        if (!supportnft[nft]) {
            revert NotSupportedNFT();
        }
        if (ts < floorlimit || ts > ceillimit) {
            revert InvalidStakingTime();
        }
        if (blacked(staker)) {
            if (blackRemaingSeconds(staker) == 0) {
                delete blackInfo[staker];
            } else {
                revert InBannedStatus();
            }
        }
    }

    /**
     * @notice Return the remaining time of the player's blacklist state.
     */
    function blackRemaingSeconds(address player) public view returns (uint256) {
        uint256 blackts = blackInfo[player];
        uint256 ts = block.timestamp;
        if (ts > blackts) {
            return 0;
        } else {
            return blackts - ts;
        }
    }

    /**
     * @notice Return the maximum of the staking time and blacklist time.
     */
    function stakEndts(
        address nft,
        address player,
        uint256 nftId
    ) public view returns (uint256) {
        uint256 blackts = blackInfo[player];
        uint256 packdata = stakeInfo[nft][nftId];
        uint256 stakets;
        (, stakets) = _unpackedStakeInfo(packdata);

        return blackts > stakets ? blackts : stakets;
    }

    function renounceOwnership() public view override onlyOwner {
        revert("Closed_Interface");
    }

    function blacked(address player) private view returns (bool) {
        return blackInfo[player] != 0;
    }

    /**
     * @notice Validate that the sender matches the staking address.
     */
    function stakeDataCheck(
        address sender,
        address nft,
        uint256 nftId
    ) private view returns (uint256 endts) {
        uint256 stakets;
        address staker;
        (staker, stakets) = stakeData(nft, nftId);
        require(sender == staker, "Without staking permission");
        return stakets;
    }

    /**
     * @notice Return the staking information, including the staking address and time, for a specific NFT contract and NFT ID.
     */
    function stakeData(address nft, uint256 nftId)
        public
        view
        returns (address, uint256)
    {
        uint256 packdata = stakeInfo[nft][nftId];
        return _unpackedStakeInfo(packdata);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

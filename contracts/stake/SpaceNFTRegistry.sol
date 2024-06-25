// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface SpaceNFTBurn {
    function burn(uint256 tokenId) external;
}

contract SpaceNFTRegistry is Ownable, ReentrancyGuard {
    using ECDSA for bytes32;
    //The minimum registration period is 3 days, and the maximum is 365 days.
    uint64 floorlimit = 3 days;
    uint64 ceillimit = 365 days;
    // The default expiration time for signatures is 300 seconds (5 minutes).
    uint32 private expireTime = 300;
    uint32 limitIdLen = 50;
    //The maximum duration of blacking is 90 days.
    uint64 constant BANCEIL = 90 days;
    // The global switch that controls the entire system. When activated, all registed  assets can be withdrawn regardless of the normal registration conditions.
    uint256 globalswitch;
    // The mask of the lower 160 bits for addresses.
    uint256 private constant _BITMASK_ADDRESS = (1 << 160) - 1;
    // The bit position of `startTimestamp` in packed ownership.
    uint256 private constant _BITPOS_START_TIMESTAMP = 160;
    // The signature address.
    address private _cosigner = 0xDa801D3cCE8626Bd55387554Bb3BE500681Cb49C;
    // The program address for implementing black and redeem.
    address miner = 0xDa801D3cCE8626Bd55387554Bb3BE500681Cb49C;
    // The address-specific switch. When this is turned on, the associated address can withdraw their registed assets regardless of the normal conditions.
    mapping(address => uint256) addrswitch;
    // The switch for a specific NFTID. When this is enabled, only the registration associated with that particular NFT ID can be directly withdrawn, ignoring normal registration conditions.
    mapping(address => mapping(uint256 => uint256)) nftswitch;
    // The NFT contracts that are supported by the registration contract.
    mapping(address => bool) supportnft;
    // The registration information for specific NFT IDs from the supported NFT contract's Id.
    mapping(address => mapping(uint256 => uint256)) private registerInfo;
    // The blacking information for specific addresses.
    mapping(address => uint256) banInfo;
    // The functionality to check if a given signature has already been used before.
    mapping(uint64 => bool) private sigvalue;

    // user operation
    event Register(
        address nft,
        address register,
        uint256 timestamp,
        uint256[] nftId
    );
    event Unregister(address nft, address register, uint256[] nftId);
    event Renewal(
        address nft,
        address register,
        uint256 nftId,
        uint256 timestamp
    );
    event Burn(uint64 signId);
    // miner operation
    event Ban(uint256 timestamp, address[] players);
    event ReduceBanningDuration(address player, uint256 timestamp);

    error InBannedStatus();
    error UnableToUnregister();
    error InvalidRegistrationTime();
    error NotSupportedNFT();
    error InvalidRenewalTime();
    error ExceedBanCeil();

    constructor(address[] memory nfts) {
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
     * @notice Only the contract owner can update the limitIdLen of batch-registration
     */
    function setLimitLen(uint32 _limitIdLen) external onlyOwner {
        limitIdLen = _limitIdLen;
    }

    /**
     * @notice Only the contract owner can update the list of NFT contracts that are supported or unsupported by the registration contract.
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
     * @notice Only the contract owner can update the minimum and maximum registration period.
     */
    function updateTsLimit(uint64 floorts, uint64 ceilts) external onlyOwner {
        floorlimit = floorts;
        ceillimit = ceilts;
    }

    /**
     * @notice Only the contract owner can enable the global switch for a duration time.
     */
    function setGloSwitch(uint256 duration) external onlyOwner {
        uint256 ts = block.timestamp;
        globalswitch = ts + duration;
    }

    /**
     * @notice Only the contract owner can enable the address-specific switch for a specific address and a set duration.
     */
    function setAddrSwitch(address addr, uint256 duration) external onlyOwner {
        uint256 ts = block.timestamp;
        addrswitch[addr] = ts + duration;
    }

    /**
     * @notice Only the contract owner can enable the NFTID-specific switch for a specific NFT contract and a set duration.
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
     * @notice Registration requires a supported NFT and a valid timestamp duration between the floor limit and ceiling limit. Meanwhile, the transaction reverts if the sender is on the banlist, and the banlist information will be deleted if the sender is not on the banlist or the banlist duration has ended.
     */
    function registration(
        address nft,
        uint256[] calldata nftIds,
        uint256 timestamp
    ) external nonReentrant {
        address register = _msgSender();
        uint256 len = nftIds.length;
        require(len <= limitIdLen, "Exceed maximum length");
        checkts(nft, timestamp, register);
        uint256 nftId;
        uint256 endts = timestamp + block.timestamp;
        uint256 packdata = _packRegisterData(register, endts);
        for (uint256 index = 0; index < len; index++) {
            nftId = nftIds[index];
            registerInfo[nft][nftId] = packdata;
            IERC721(nft).safeTransferFrom(register, address(this), nftId);
        }
        emit Register(nft, register, endts, nftIds);
    }

    /**
     * @notice For Unregistration, the sender must be the address that registed  the NFTID. They can unregister the NFTID if any switches are enabled for him, or if the maximum between registration and banlist durations have ended. Unregistration will delete the banlist state for the player.
     */
    function unregistration(address nft, uint256[] calldata nftIds)
        external
        nonReentrant
    {
        address unregister = _msgSender();
        uint256 len = nftIds.length;
        require(len <= limitIdLen, "Exceed maximum length");
        uint256 nftId;
        uint256 ts = block.timestamp;
        bool temstatus = globalswitch > ts || addrswitch[unregister] > ts;
        for (uint256 index = 0; index < len; index++) {
            nftId = nftIds[index];
            registerDataCheck(unregister, nft, nftId);
            bool status = temstatus || nftswitch[nft][nftId] > ts;
            if (!status) {
                uint256 maxts = stakEndts(nft, unregister, nftId);
                if (ts > maxts) {
                    delete banInfo[unregister];
                } else {
                    revert UnableToUnregister();
                }
            }
            delete registerInfo[nft][nftId];
            IERC721(nft).safeTransferFrom(address(this), unregister, nftId);
        }

        emit Unregister(nft, unregister, nftIds);
    }

    /**
     * @notice For renewal a register duration, the sender must be the address that registed the NFTID. They can renewal the registration duration for the specific NFT ID. Renewaling will delete the banlist state if the sender has been banlisted but the banlisted duration has now expired.
     */
    function registrationRenewal(
        address nft,
        uint256[] calldata nftIds,
        uint64 timestamp
    ) external {
        address register = _msgSender();
        checkts(nft, timestamp, register);
        uint256 len = nftIds.length;
        require(len <= limitIdLen, "Exceed maximum length");
        uint256 nftId;
        uint256 ts = block.timestamp;
        for (uint256 index = 0; index < len; index++) {
            nftId = nftIds[index];
            uint256 registerts = registerDataCheck(register, nft, nftId);
            uint256 endts = ts > registerts ? ts : registerts;
            endts += timestamp;
            if (endts - ts > ceillimit) {
                endts = ts + ceillimit;
            }
            registerInfo[nft][nftId] = _packRegisterData(register, endts);
            emit Renewal(nft, register, nftId, endts);
        }
    }

    /**
     * @notice Only the Miner can ban players who are not already in a banlisted state, for a maximum duration of BANCEIL.
     */
    function ban(address[] calldata players, uint256 timestamp)
        external
        onlyMiner
    {
        if (timestamp > BANCEIL) {
            revert ExceedBanCeil();
        }
        address player;
        uint256 len = players.length;
        require(len <= limitIdLen, "Exceed maximum length");
        uint256 endts = timestamp + block.timestamp;
        for (uint256 index = 0; index < len; index++) {
            player = players[index];
            require((banInfo[player] == 0), "The user has been banned");
            banInfo[player] = endts;
        }
        emit Ban(endts, players);
    }

    /**
     * @notice Only the Miner can reduce the banning duration for players.
     */
    function reduceBanningDuration(
        address[] calldata players,
        uint256 timestamp
    ) external onlyMiner {
        address player;
        uint256 len = players.length;
        require(len <= limitIdLen, "Exceed maximum length");
        for (uint256 index = 0; index < len; index++) {
            player = players[index];
            uint256 remaingts = blackRemaingSeconds(player);
            if (remaingts <= timestamp) {
                delete banInfo[player];
            } else {
                banInfo[player] -= timestamp;
            }
            emit ReduceBanningDuration(player, banInfo[player]);
        }
    }

    /**
     * @notice Registers can burn the in-game items (NFTs) to upgrade or disassemble operations in specific game scenarios
     */
    function burn(
        address nft,
        uint32[] calldata nftIds,
        uint64 timestamp,
        uint64 uuid,
        uint64 signId,
        bytes memory sig
    ) external {
        assertValidCosign(nft, nftIds, timestamp, uuid, signId, sig);
        uint32 nftId;
        uint256 len = nftIds.length;
        address register = _msgSender();
        if (blackRemaingSeconds(register) != 0) {
            revert InBannedStatus();
        }
        for (uint256 i = 0; i < len; i++) {
            nftId = nftIds[i];
            registerDataCheck(register, nft, nftId);
            delete registerInfo[nft][nftId];
            SpaceNFTBurn(nft).burn(nftId);
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
        require((!sigvalue[uuid]), "HAS_USED");
        sigvalue[uuid] = true;
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
     * @notice Returns the packed data based on the registration address and time duration.
     */
    function _packRegisterData(address owner, uint256 ts)
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
     * @notice Returns the unpacked registration address and time duration from `packed`.
     */
    function _unpackedRegisterInfo(uint256 packed)
        private
        pure
        returns (address, uint256)
    {
        return (address(uint160(packed)), packed >> _BITPOS_START_TIMESTAMP);
    }

    /**
     * @notice Validate the NFT address, registration duration, and banlist state.
     */
    function checkts(
        address nft,
        uint256 ts,
        address register
    ) internal {
        if (!supportnft[nft]) {
            revert NotSupportedNFT();
        }
        if (ts < floorlimit || ts > ceillimit) {
            revert InvalidRegistrationTime();
        }
        if (blacked(register)) {
            if (blackRemaingSeconds(register) == 0) {
                delete banInfo[register];
            } else {
                revert InBannedStatus();
            }
        }
    }

    /**
     * @notice Return the remaining time of the player's banlist state.
     */
    function blackRemaingSeconds(address player) public view returns (uint256) {
        uint256 blackts = banInfo[player];
        uint256 ts = block.timestamp;
        if (ts > blackts) {
            return 0;
        } else {
            return blackts - ts;
        }
    }

    /**
     * @notice Return the maximum of the registration time and banlist time.
     */
    function stakEndts(
        address nft,
        address player,
        uint256 nftId
    ) public view returns (uint256) {
        uint256 blackts = banInfo[player];
        uint256 packdata = registerInfo[nft][nftId];
        uint256 registerts;
        (, registerts) = _unpackedRegisterInfo(packdata);

        return blackts > registerts ? blackts : registerts;
    }

    function renounceOwnership() public view override onlyOwner {
        revert("Closed_Interface");
    }

    function blacked(address player) private view returns (bool) {
        return banInfo[player] != 0;
    }

    /**
     * @notice Validate that the sender matches the registration address.
     */
    function registerDataCheck(
        address sender,
        address nft,
        uint256 nftId
    ) private view returns (uint256 endts) {
        address register;
        (register, endts) = registerData(nft, nftId);
        require(sender == register, "Without registration permission");
    }

    /**
     * @notice Return the registration information, including the registration address and time, for a specific NFT contract and NFT ID.
     */
    function registerData(address nft, uint256 nftId)
        public
        view
        returns (address, uint256)
    {
        uint256 packdata = registerInfo[nft][nftId];
        return _unpackedRegisterInfo(packdata);
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

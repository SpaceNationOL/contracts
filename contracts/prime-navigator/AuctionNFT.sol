// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface INFTMinter {
    function nftcallermint(address recipient, uint256 count)
        external
        returns (bool);
}

contract StakeNFT is Context, ReentrancyGuard {
    struct ClaimInfo {
        bool hasClaimedNFT;
        bool hasRefundedETH;
        uint256 refundAmount;
        uint256 transferAmount;
        uint256 nftCount;
    }

    struct Stake {
        uint256 id;
        address staker;
        uint256 price;
        uint256 timestamp;
    }

    event StakeEV(
        address indexed staker,
        uint256 indexed id,
        uint256 indexed timestamp,
        uint256 price
    );
    event Airdrop(
        address indexed staker,
        uint256 indexed nftAmount,
        uint256 indexed transferAmount
    );
    event Refund(address indexed staker, uint256 indexed refundAmount);
    event RaffleWon(uint256 indexed winner);

    address public immutable manager; /// The address of the contract manager.
    address public nftAddress; ///The address of the NFT contract.
    address public revenueWallet; ///The address of the wallet where revenue from NFT mints will be sent.
    uint256 public allstakeStart; ///The start time of the staking period.
    uint256 public allstakeEnd; ///The end time of the staking period.
    uint256 public GTDStart; ///The start time of the GTD whitelist staking period.
    uint256 public GTDEnd; ///The end time of the GTD whitelist staking period.
    uint256 public BackupEnd; ///The end time of the backup staking period.
    uint256 public revealRaffle; /// The time when the raffle will be revealed.
    uint256 public refundTime; /// The time when the user to airdrop/refund.
    uint256 private _counter;
    uint256 private immutable _ExtendAllstakeEnd;
    uint256 private immutable _ExtendGTDEnd;
    uint256 private immutable _ExtendBackupEnd;
    uint256 private immutable _ExtendRaffleEnd;
    uint256 private immutable _ExtendRefundTime;
    uint256 public immutable raffleCount; ///The number of NFTs that will be awarded to stakers during the raffle.
    uint256 public remainRaffleCount; ///The number of NFTs that will be awarded to stakers during the raffle.
    uint256 public avaWLCount; ///The number of NFTs that are available for Backup staking.
    uint256 public constant WHITESTAKEPRICE = 0.3 ether;
    uint256 public constant PUBLICSTAKEPRICE = 0.4 ether;
    uint256 public constant ONEDAY = 1 days;
    uint256 private executeNumber;
    uint256 private seedsInitialized;
    string public seeds;
    address[] public stakes;
    uint256[] private _publicStakesId; ///The array of staking ids in the allstakeStart~allstakeEnd period.
    uint256[] private _whiteStakesId; ///The array of staking ids in the GTDStart~BackupEnd period.

    mapping(address => bool) private _inStakes; ///Maps sender to whether he is in the staking array or not.
    mapping(address => uint256[]) private _userStakes; ///Maps stakers to their all staking IDs.
    mapping(uint256 => Stake) public stakeIdInfo; ///Maps staking IDs to their staking information.
    mapping(address => bool) public hasClaimedNFT; ///Maps stakers to whether they have claimed their NFTs or not.
    mapping(address => bool) public hasRefundedETH; ///Maps stakers to whether they have received a refund or not.
    mapping(uint256 => bool) public raffleWon; ///Maps staking IDs to whether they have won the raffle or not.
    mapping(address => bool) public GTDAddress; ///Maps sender to whether they are GTD whitelisted or not.
    mapping(address => uint256) public GTDTickets; ///Maps GTD whitelisted sender to their allowed staking number.
    mapping(address => bool) public BackupAddress; ///Maps sender to whether they are Backup whitelisted or not.
    mapping(address => bool) public BackupStaked; ///Maps Backup whitelisted sender to whether they have staked or not.

    constructor(
        address _manager,
        address _nftAddress,
        address _revenueWallet,
        uint256 _raffleCount,
        uint256 _avaWLCount,
        uint256 _allstakeStart,
        uint256 _allstakeEnd,
        uint256 _GTDStart,
        uint256 _GTDEnd,
        uint256 _BackupEnd,
        uint256 _revealRaffle,
        uint256 _refundTime
    ) {
        require(
            _allstakeEnd >= _allstakeStart,
            "allstakeStart less than allstakeEnd"
        );
        require(_GTDEnd >= _GTDStart, "GTDEnd less than GTDStart");
        require(_BackupEnd >= _GTDEnd, "BackupEnd less than GTDEnd");
        require(
            _revealRaffle >= _BackupEnd,
            "revealRaffle less than BackupEnd"
        );
        require(
            _refundTime >= _revealRaffle,
            "refundTime less than revealRaffle"
        );
        require(_manager != address(0), "invalid _manager address");
        require(_nftAddress != address(0), "invalid _nftAddress address");
        require(_revenueWallet != address(0), "invalid _revenueWallet address");
        manager = _manager;
        nftAddress = _nftAddress;
        revenueWallet = _revenueWallet;
        raffleCount = _raffleCount;
        remainRaffleCount = raffleCount;
        avaWLCount = _avaWLCount;
        allstakeStart = _allstakeStart;
        allstakeEnd = _allstakeEnd;
        _ExtendAllstakeEnd = ONEDAY + allstakeEnd;
        GTDStart = _GTDStart;
        GTDEnd = _GTDEnd;
        _ExtendGTDEnd = ONEDAY + GTDEnd;
        BackupEnd = _BackupEnd;
        _ExtendBackupEnd = ONEDAY + BackupEnd;
        revealRaffle = _revealRaffle;
        _ExtendRaffleEnd = ONEDAY + revealRaffle;
        refundTime = _refundTime;
        _ExtendRefundTime = refundTime + refundTime;
    }

    modifier onlyManager() {
        require(_msgSender() == manager, "ONLY_MANAGER_ROLE");
        _;
    }

    /// @notice  update revenueWallet.
    function setRevenueWallet(address addr) external onlyManager {
        require(addr != address(0), "invalid address");
        revenueWallet = addr;
    }

    /// @notice  update nftAddress.
    function setNftAddress(address addr) external onlyManager {
        require(addr != address(0), "invalid address");
        require(block.timestamp <= refundTime, "Staking end");
        nftAddress = addr;
    }

    /// @notice  update allstakeEnd.
    function setAllEndTime(uint256 time) external onlyManager {
        require(time <= _ExtendAllstakeEnd, "exceed maximum period");
        require(time >= allstakeStart, "must more than allstakeStart time");
        allstakeEnd = time;
    }

    /// @notice  update GTDEnd.
    function setGTDEndTime(uint256 time) external onlyManager {
        require(time <= _ExtendGTDEnd, "exceed maximum period");
        require(time >= GTDStart, "must more than GTDStart time");
        GTDEnd = time;
    }

    /// @notice  update BackupEnd.
    function setBackupEndTime(uint256 time) external onlyManager {
        require(time <= _ExtendBackupEnd, "exceed maximum period");
        require(time >= GTDEnd, "must more than GTDEnd time");
        BackupEnd = time;
    }

    /// @notice  update revealRaffle.
    function setRaffleTime(uint256 time) external onlyManager {
        require(time <= _ExtendRaffleEnd, "exceed maximum period");
        require(time >= BackupEnd, "must more than BackupEnd time");
        revealRaffle = time;
    }

    /// @notice  update refundTime.
    function setOperationTime(uint256 time) external onlyManager {
        require(time <= _ExtendRefundTime, "exceed maximum period");
        require(time >= revealRaffle, "must more than revealRaffle");
        refundTime = time;
    }

    /// @notice  set non-duplicated GTD whitelist address and their allowed staking tickets.
    function setGTDlist(
        address[] calldata GTDAddrs,
        uint256[] calldata GTDTicks
    ) external onlyManager {
        uint256 GTDAddrLength = GTDAddrs.length;
        uint256 GTDTickslength = GTDTicks.length;
        require(GTDAddrLength == GTDTickslength, "Mismatched length");
        address waddr;
        uint256 ticket;
        for (uint256 i = 0; i < GTDTickslength; i++) {
            waddr = GTDAddrs[i];
            ticket = GTDTicks[i];
            GTDAddress[waddr] = true;
            GTDTickets[waddr] = ticket;
        }
    }

    /// @notice  set non-duplicated Backup whitelist address.
    function setBackuplist(address[] calldata BackupAddrs)
        external
        onlyManager
    {
        address waddr;
        uint256 length = BackupAddrs.length;
        for (uint256 i = 0; i < length; i++) {
            waddr = BackupAddrs[i];
            BackupAddress[waddr] = true;
        }
    }

    /// @notice Allows users to stake ETH during a certain period of time.
    function allStake() external payable {
        require(
            block.timestamp >= allstakeStart,
            "StakeNFT: public stake not start"
        );
        require(block.timestamp <= allstakeEnd, "StakeNFT: public stake ended");
        uint256 value = msg.value;
        require(value != 0, "StakeNFT: invalid staking value");
        require(
            value % PUBLICSTAKEPRICE == 0,
            "StakeNFT: invalid staking value"
        );
        uint256 tickets = value / PUBLICSTAKEPRICE;
        for (uint256 i = 0; i < tickets; i++) {
            uint256 newId = uint256(keccak256(abi.encodePacked(_counter)));
            _counter += 1;
            Stake memory newStake = Stake(
                newId,
                _msgSender(),
                PUBLICSTAKEPRICE,
                block.timestamp
            );
            _userStakes[_msgSender()].push(newId);
            _publicStakesId.push(newId);
            stakeIdInfo[newId] = newStake;
            emit StakeEV(
                _msgSender(),
                newId,
                block.timestamp,
                PUBLICSTAKEPRICE
            );
        }
        if (!_inStakes[_msgSender()]) {
            _inStakes[_msgSender()] = true;
            stakes.push(_msgSender());
        }
    }

    /// @notice  Allows users who have been GTDwhitelisted to stake NFTs during a separate period of time.
    function GTDStake() external payable {
        require(block.timestamp >= GTDStart, "StakeNFT: GTD not start");
        require(block.timestamp < GTDEnd, "StakeNFT: GTD ended");
        require(GTDAddress[_msgSender()], "StakeNFT: not GTD address");
        uint256 tickets = GTDTickets[_msgSender()];
        require(tickets != 0, "StakeNFT: no qualifications left");
        uint256 value = msg.value;
        require(value != 0, "StakeNFT: invalid staking value");
        require(
            value % WHITESTAKEPRICE == 0,
            "StakeNFT: invalid staking value"
        );
        require(
            value <= tickets * WHITESTAKEPRICE,
            "StakeNFT: exceed maximum staking value"
        );

        tickets = value / WHITESTAKEPRICE;
        require(
            tickets <= avaWLCount,
            "StakeNFT: exceed maximum left staking qualifications"
        );
        avaWLCount -= tickets;
        GTDTickets[_msgSender()] -= tickets;
        for (uint256 i = 0; i < tickets; i++) {
            uint256 newId = uint256(keccak256(abi.encodePacked(_counter)));
            _counter += 1;
            Stake memory newStake = Stake(
                newId,
                _msgSender(),
                WHITESTAKEPRICE,
                block.timestamp
            );
            _userStakes[_msgSender()].push(newId);
            _whiteStakesId.push(newId);
            stakeIdInfo[newId] = newStake;
            emit StakeEV(_msgSender(), newId, block.timestamp, WHITESTAKEPRICE);
        }
        if (!_inStakes[_msgSender()]) {
            _inStakes[_msgSender()] = true;
            stakes.push(_msgSender());
        }
    }

    /// @notice  Allows users who have been Backupwhitelisted to stake NFTs during a separate period of time.
    function backupStake() external payable {
        require(avaWLCount != 0, "StakeNFT: no stake qualifications left");
        require(block.timestamp >= GTDEnd, "StakeNFT: Backup not start");
        require(block.timestamp <= BackupEnd, "StakeNFT: Backup ended");
        require(BackupAddress[_msgSender()], "StakeNFT: not Backup address");

        uint256 value = msg.value;
        require(value == WHITESTAKEPRICE, "StakeNFT: invalid staking value");
        require(!BackupStaked[_msgSender()], "StakeNFT: already staked");
        avaWLCount -= 1;
        BackupStaked[_msgSender()] = true;

        uint256 newId = uint256(keccak256(abi.encodePacked(_counter)));
        _counter += 1;
        Stake memory newStake = Stake(
            newId,
            _msgSender(),
            WHITESTAKEPRICE,
            block.timestamp
        );
        _userStakes[_msgSender()].push(newId);
        _whiteStakesId.push(newId);
        stakeIdInfo[newId] = newStake;
        if (!_inStakes[_msgSender()]) {
            _inStakes[_msgSender()] = true;
            stakes.push(_msgSender());
        }
        emit StakeEV(_msgSender(), newId, block.timestamp, WHITESTAKEPRICE);
    }

    /// @notice  Input random seeds.
    /// @param seed The random seed generated off-chain, which is a public and random info that could be verified anytime and anyone.
    function raffleSeed(string memory seed) external onlyManager {
        require(seedsInitialized == 0, "seeds already initialized");
        require(
            block.timestamp >= BackupEnd,
            "StakeNFT: raffle seeds not start"
        );
        require(block.timestamp <= refundTime, "StakeNFT: raffle seeds ended");
        seedsInitialized = 1;
        seeds = seed;
    }

    /// @notice  Executes a raffle to determine which stakers win NFTs.
    /// @param count The count determines how many stakes will be executed raffle in this loop condition.
    function executeRaffle(uint256 count) external {
        require(seedsInitialized == 1, "seeds not initialized");
        uint256 length = _publicStakesId.length;
        if (length <= raffleCount) {
            uint256 ncount = executeNumber + count >= length
                ? length
                : executeNumber + count;
            uint256 temp = executeNumber;
            executeNumber = ncount;
            for (uint256 i = temp; i < ncount; i++) {
                uint256 stakeid = _publicStakesId[i];
                raffleWon[stakeid] = true;
                emit RaffleWon(stakeid);
            }
        } else {
            if (count > remainRaffleCount) {
                count = remainRaffleCount;
            }
            remainRaffleCount -= count;
            for (uint256 i = 0; i < count; i++) {
                executeNumber++;
                uint256 index = uint256(
                    keccak256(abi.encodePacked(seeds, executeNumber, i))
                ) % length;
                uint256 stakeid = _publicStakesId[index];
                while (raffleWon[stakeid]) {
                    index = index < length - 1 ? index + 1 : 0;
                    stakeid = _publicStakesId[index];
                }
                raffleWon[stakeid] = true;
                emit RaffleWon(stakeid);
            }
        }
    }

    /// @notice   Returns information about a staker's stake, including whether they have claimed their NFTs or received a refund
    function claimInfo() external view returns (ClaimInfo memory info) {
        info = claimInfo(_msgSender());
    }

    function claimInfo(address addr)
        public
        view
        returns (ClaimInfo memory info)
    {
        if (block.timestamp < revealRaffle) {
            return info;
        }
        info.hasRefundedETH = hasRefundedETH[addr];
        info.hasClaimedNFT = hasClaimedNFT[addr];
        info.refundAmount = 0;
        info.nftCount = 0;
        info.transferAmount = 0;
        uint256[] memory stakedId = _userStakes[addr];
        uint256 length = stakedId.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 stakeId = stakedId[i];
            Stake memory stakeInfo = stakeIdInfo[stakeId];
            uint256 stakedPrice = stakeInfo.price;
            if (stakedPrice == WHITESTAKEPRICE || raffleWon[stakeId]) {
                info.nftCount += 1;
                info.transferAmount += stakedPrice;
            } else {
                info.refundAmount += stakedPrice;
            }
        }
    }

    /// @notice   Airdrop stakers NFTs if they have won the raffle.
    /// @param start The start determines the start position of the stakers array in this loop condition.
    /// @param count The count determines how many stakes will be airdroped in this loop condition.
    function airdrop(uint256 start, uint256 count) external nonReentrant {
        require(block.timestamp >= refundTime, "StakeNFT: airdrop not start");
        uint256 length = stakes.length;
        uint256 ncount = start + count >= length ? length : start + count;
        for (uint256 j = start; j < ncount; j++) {
            address staker = stakes[j];
            ClaimInfo memory info = claimInfo(staker);
            if (!info.hasClaimedNFT) {
                hasClaimedNFT[staker] = true;
                if (info.transferAmount != 0) {
                    Address.sendValue(
                        payable(revenueWallet),
                        info.transferAmount
                    );
                }

                if (info.nftCount != 0) {
                    require(
                        INFTMinter(nftAddress).nftcallermint(
                            staker,
                            info.nftCount
                        ),
                        "nftcallermint failed"
                    );
                }
                emit Airdrop(staker, info.nftCount, info.transferAmount);
            }
        }
    }

    /// @notice   Allows stakers to receive a refund if they have not won the raffle.
    function refund() external nonReentrant {
        require(block.timestamp >= refundTime, "StakeNFT: refund not start");
        address staker = _msgSender();
        ClaimInfo memory info = claimInfo(staker);

        require(!info.hasRefundedETH, "StakeNFT: has refunded");
        require(info.refundAmount > 0, "StakeNFT: nothing to refund");

        hasRefundedETH[staker] = true;
        Address.sendValue(payable(staker), info.refundAmount);

        emit Refund(staker, info.refundAmount);
    }

    /**************** View Functions ****************/
    function tvl() external view returns (uint256) {
        return address(this).balance;
    }

    function getUserStakes(
        address addr,
        uint256 start,
        uint256 count
    ) external view returns (Stake[] memory stakesinfo) {
        uint256[] memory stakeId = getUserTickets(addr, start, count);
        uint256 length = stakeId.length;
        stakesinfo = new Stake[](length);
        for (uint256 j = 0; j < length; j++) {
            uint256 id = stakeId[j];
            stakesinfo[j] = stakeIdInfo[id];
        }
    }

    function getUserTickets(
        address addr,
        uint256 start,
        uint256 count
    ) public view returns (uint256[] memory) {
        uint256 length = _userStakes[addr].length;
        uint256 ncount = start + count >= length ? length : start + count;
        uint256 index;
        uint256 arraylen = ncount - start;
        uint256[] memory usertickets = new uint256[](arraylen);
        for (uint256 j = start; j < ncount; j++) {
            usertickets[index] = _userStakes[addr][j];
            index++;
        }
        return usertickets;
    }

    function getWhiStakeIds() external view returns (uint256) {
        return _whiteStakesId.length;
    }

    function getWhiStakeIdInfo() external view returns (uint256[] memory) {
        return _whiteStakesId;
    }

    function getPubStakeIds() external view returns (uint256) {
        return _publicStakesId.length;
    }

    function getPubStakeIdInfo() external view returns (uint256[] memory) {
        return _publicStakesId;
    }

    function getRaffledId(uint256 start, uint256 count)
        external
        view
        returns (uint256[] memory raffleIds)
    {
        if (block.timestamp < revealRaffle) {
            return raffleIds;
        }
        uint256 length = _publicStakesId.length;
        uint256 ncount = start + count >= length ? length : start + count;
        uint256 counts = ncount - start;
        uint256[] memory raffleId = new uint256[](counts);
        uint256 index;

        for (uint256 j = start; j < counts; j++) {
            uint256 stakeid = _publicStakesId[j];
            if (raffleWon[stakeid]) {
                raffleId[index] = stakeid;
                index++;
            }
        }
        return raffleId;
    }
}

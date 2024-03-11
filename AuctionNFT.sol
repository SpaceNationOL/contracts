// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract StakeNFT is Context {
    /// @notice hasClaimedNFT symbols whether a staker has claimed his NFT.
    /// @notice hasRefundedETH symbols whether a staker has refunded his staking token.
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
        uint256 indexed timestamp
    );
    event Claim(
        address indexed staker,
        uint256 indexed nftAmount,
        uint256 indexed transferAmount
    );
    event Refund(address indexed staker, uint256 indexed refundAmount);
    event RaffleWon(uint256 indexed winner);

    using Counters for Counters.Counter;
    Counters.Counter private _idCounter;

    address public manager; /// The address of the contract manager.
    address public nftAddress; ///The address of the NFT contract.
    address public revenueWallet; ///The address of the wallet where revenue from NFT mints will be sent.
    uint256 public allstakeStart; ///The start time of the staking period.
    uint256 public allstakeEnd; ///The end time of the staking period.
    uint256 public GTDStart; ///The start time of the GTD whitelist staking period.
    uint256 public GTDEnd; ///The end time of the GTD whitelist staking period.
    uint256 public BackupEnd; ///The end time of the backup staking period.
    uint256 public raffleTime; /// The time when the raffle will be executed.
    uint256 public operationTime; /// The time when the user to cliam/refund.
    uint256 private ExtendAllstakeEnd;
    uint256 private ExtendGTDEnd;
    uint256 private ExtendBackupEnd;
    uint256 private ExtendRaffleEnd;
    uint256 private ExtendOperationTime;

    uint256 public raffleCount; ///The number of NFTs that will be awarded to stakers during the raffle.
    uint256 public remainRaffleCount; ///The number of NFTs that will be awarded to stakers during the raffle.
    uint256 public avaWLCount; ///The number of NFTs that are available for Backup staking.
    uint256[] private _publicStakesId; ///The array of staking ids in the allstakeStart~allstakeEnd period.
    uint256[] private _whiteStakesId; ///The array of staking ids in the GTDStart~BackupEnd period.
    uint256 public constant WHITESTAKEPRICE = 0.3 ether;
    uint256 public constant PUBLICSTAKEPRICE = 0.4 ether;
    uint256 public constant ONEDAY = 24 hours;

    mapping(address => uint256[]) private userStakes; ///Maps stakers to their staking IDs.
    mapping(uint256 => Stake) public stakeIdInfo; ///Maps staking IDs to their respective staking information.
    mapping(address => bool) public hasClaimedNFT; ///Maps stakers to whether they have claimed their NFTs.
    mapping(address => bool) public hasRefundedETH; ///Maps stakers to whether they have received a refund.
    mapping(uint256 => bool) public raffleWon; ///Maps staking IDs to whether they have won the raffle.
    mapping(address => bool) public GTDAddress; ///Maps sender to whether they are GTD whitelisted.
    mapping(address => uint256) public GTDTickets; ///Maps GTD whitelisted sender to their allowed staking number.
    mapping(address => bool) public BackupAddress; ///Maps sender to whether they are Backup whitelisted.
    mapping(address => bool) public BackupStaked; ///Maps Backup whitelisted sender to whether they have staked.

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
        uint256 _raffleTime,
        uint256 _operationTime
    ) {
        require(
            _allstakeEnd >= _allstakeStart,
            "allstakeStart less than allstakeEnd"
        );
        require(_GTDEnd >= _GTDStart, "GTDEnd less than GTDStart");
        require(_BackupEnd >= _GTDEnd, "BackupEnd less than GTDEnd");
        require(_raffleTime >= _BackupEnd, "raffleTime less than BackupEnd");
        require(
            _operationTime >= _raffleTime,
            "operationTime less than raffleTime"
        );
        manager = _manager;
        nftAddress = _nftAddress;
        revenueWallet = _revenueWallet;
        raffleCount = _raffleCount;
        remainRaffleCount = raffleCount;
        avaWLCount = _avaWLCount;
        allstakeStart = _allstakeStart;
        allstakeEnd = _allstakeEnd;
        ExtendAllstakeEnd = ONEDAY + allstakeEnd;
        GTDStart = _GTDStart;
        GTDEnd = _GTDEnd;
        ExtendGTDEnd = ONEDAY + GTDEnd;
        BackupEnd = _BackupEnd;
        ExtendBackupEnd = ONEDAY + BackupEnd;
        raffleTime = _raffleTime;
        ExtendRaffleEnd = ONEDAY + raffleTime;
        operationTime = _operationTime;
        ExtendOperationTime = operationTime + operationTime;
    }

    modifier onlyManager() {
        require(_msgSender() == manager, "ONLY_MANAGER_ROLE");
        _;
    }

    receive() external payable {}

    /// @notice  update revenueWallet.
    function setRevenueWallet(address _r) external onlyManager {
        require(_r != address(0), "invalid address");
        revenueWallet = _r;
    }

    /// @notice  update nftAddress.
    function setNftAddress(address _addr) external onlyManager {
        require(_addr != address(0), "invalid address");
        nftAddress = _addr;
    }

    /// @notice  update GTDEnd.
    function setGTDEndTime(uint256 _t) external onlyManager {
        require(_t <= ExtendGTDEnd, "exceed maximum period");
        require(_t >= GTDStart, "must more than GTDStart time");
        GTDEnd = _t;
    }

    /// @notice  update BackupEnd.
    function setBackupEndTime(uint256 _t) external onlyManager {
        require(_t <= ExtendBackupEnd, "exceed maximum period");
        require(_t >= GTDEnd, "must more than GTDEnd time");
        BackupEnd = _t;
    }

    /// @notice  update raffleTime.
    function setRaffleTime(uint256 _t) external onlyManager {
        require(_t <= ExtendRaffleEnd, "exceed maximum period");
        require(_t >= BackupEnd, "must more than BackupEnd time");
        raffleTime = _t;
    }

    /// @notice  update raffleTime.
    function setOperationTime(uint256 _t) external onlyManager {
        require(_t <= ExtendOperationTime, "exceed maximum period");
        require(_t >= raffleTime, "must more than raffleTime");
        operationTime = _t;
    }

    /// @notice  set non-deplicated GTD whitelist address and their allowed staking tickets.
    function setGTDlist(
        address[] calldata GTDAddrs,
        uint256[] calldata GTDTicks
    ) external onlyManager {
        require(GTDAddrs.length == GTDTicks.length, "MisMatchged length");
        address waddr;
        uint256 ticket;
        for (uint256 i = 0; i < GTDAddrs.length; i++) {
            waddr = GTDAddrs[i];
            ticket = GTDTicks[i];
            GTDAddress[waddr] = true;
            GTDTickets[waddr] = ticket;
        }
    }

    /// @notice  set non-deplicated Backup whitelist address.
    function setBackuplist(address[] calldata BackupAddrs)
        external
        onlyManager
    {
        address waddr;
        for (uint256 i = 0; i < BackupAddrs.length; i++) {
            waddr = BackupAddrs[i];
            BackupAddress[waddr] = true;
        }
    }

    /// @notice Allows users to stake ETH during a certain period of time.
    function allStake() external payable {
        require(block.timestamp >= allstakeStart, "StakeNFT: stake not start");
        require(block.timestamp <= allstakeEnd, "StakeNFT: stake ended");
        uint256 value = msg.value;
        require(value != 0, "StakeNFT: invalid staking value");
        require(
            SafeMath.mod(value, PUBLICSTAKEPRICE) == 0,
            "StakeNFT: invalid staking value"
        );
        uint256 tickets = SafeMath.div(value, PUBLICSTAKEPRICE);
        for (uint256 i = 0; i < tickets; i++) {
            uint256 newId = uint256(
                keccak256(abi.encodePacked(_idCounter.current()))
            );
            _idCounter.increment();
            Stake memory newStake = Stake(
                newId,
                _msgSender(),
                PUBLICSTAKEPRICE,
                block.timestamp
            );
            userStakes[_msgSender()].push(newId);
            _publicStakesId.push(newId);
            stakeIdInfo[newId] = newStake;
            emit StakeEV(_msgSender(), newId, block.timestamp);
        }
    }

    /// @notice  Allows users who have been GTDwhitelisted to stake NFTs during a separate period of time.
    function GTDStake() external payable {
        require(
            block.timestamp >= GTDStart,
            "StakeNFT: GTD not start"
        );
        require(block.timestamp < GTDEnd, "StakeNFT: GTD ended");
        require(
            GTDAddress[_msgSender()],
            "StakeNFT: not GTD address"
        );
        uint256 tickets = GTDTickets[_msgSender()];
        require(tickets != 0, "StakeNFT: no qualifications left");
        uint256 value = msg.value;
        require(value != 0, "StakeNFT: invalid staking value");
        require(
            SafeMath.mod(value, WHITESTAKEPRICE) == 0,
            "StakeNFT: invalid staking value"
        );
        require(
            value <= tickets * WHITESTAKEPRICE,
            "StakeNFT: exceed maximum staking value"
        );

        tickets = SafeMath.div(value, WHITESTAKEPRICE);
        require(
            tickets <= avaWLCount,
            "StakeNFT: exceed maximum left staking qualifications"
        );
        GTDTickets[_msgSender()] -= tickets;
        for (uint256 i = 0; i < tickets; i++) {
            uint256 newId = uint256(
                keccak256(abi.encodePacked(_idCounter.current()))
            );
            _idCounter.increment();
            Stake memory newStake = Stake(
                newId,
                _msgSender(),
                WHITESTAKEPRICE,
                block.timestamp
            );
            userStakes[_msgSender()].push(newId);
            _whiteStakesId.push(newId);
            stakeIdInfo[newId] = newStake;
            avaWLCount -= 1;
            emit StakeEV(_msgSender(), newId, block.timestamp);
        }
    }

    /// @notice  Allows users who have been Backupwhitelisted to stake NFTs during a separate period of time.
    function backupStake() external payable {
        require(avaWLCount != 0, "StakeNFT: no stake qualifications left");
        require(
            block.timestamp >= GTDEnd,
            "StakeNFT: Backup not start"
        );
        require(
            block.timestamp <= BackupEnd,
            "StakeNFT: Backup ended"
        );
        require(
            BackupAddress[_msgSender()],
            "StakeNFT: not Backup address"
        );

        uint256 value = msg.value;
        require(value == WHITESTAKEPRICE, "StakeNFT: invalid staking value");
        require(!BackupStaked[_msgSender()], "StakeNFT: alrerady staked");
        avaWLCount -= 1;
        BackupStaked[_msgSender()] = true;

        uint256 newId = uint256(
            keccak256(abi.encodePacked(_idCounter.current()))
        );
        _idCounter.increment();
        Stake memory newStake = Stake(
            newId,
            _msgSender(),
            WHITESTAKEPRICE,
            block.timestamp
        );
        userStakes[_msgSender()].push(newId);
        _whiteStakesId.push(newId);
        stakeIdInfo[newId] = newStake;
        emit StakeEV(_msgSender(), newId, block.timestamp);
    }

    /// @notice  Executes a raffle to determine which stakers will win NFTs based on tht input seeds.
    /// @param seeds The random seed generated off-chain, which is a public and random info that could be verified anytime and anyone.
    function executeRaffle(string memory seeds, uint256 _raffleCount)
        external
        onlyManager
    {
        require(block.timestamp >= BackupEnd, "StakeNFT: stake not ended");
        if (_publicStakesId.length <= raffleCount) {
            for (uint256 i = 0; i < _publicStakesId.length; i++) {
                uint256 stakeid = _publicStakesId[i];
                raffleWon[stakeid] = true;
                emit RaffleWon(stakeid);
            }
        } else {
            require(
                remainRaffleCount >= _raffleCount,
                "StakeNFT: not enough raffle number"
            );
            remainRaffleCount -= _raffleCount;
            for (uint256 i = 0; i < _raffleCount; i++) {
                uint256 index = uint256(
                    keccak256(abi.encodePacked(seeds, _raffleCount, i))
                ) % _publicStakesId.length;
                uint256 stakeid = _publicStakesId[index];
                while (raffleWon[stakeid]) {
                    index = index < _publicStakesId.length - 1 ? index + 1 : 0;
                    stakeid = _publicStakesId[index];
                }
                raffleWon[stakeid] = true;
                emit RaffleWon(stakeid);
            }
        }
    }

    /// @notice   Returns information about a staker's stake, including whether they have claimed their NFTs or received a refund
    function claimInfo() external view returns (ClaimInfo memory info) {
        info = _claimInfo(_msgSender());
    }

    function _claimInfo(address _a)
        public
        view
        returns (ClaimInfo memory info)
    {
        require(
            block.timestamp >= raffleTime,
            "StakeNFT: Not check rewards time"
        );
        info.hasClaimedNFT = hasClaimedNFT[_a];
        info.hasRefundedETH = hasRefundedETH[_a];
        info.refundAmount = 0;
        info.nftCount = 0;
        info.transferAmount = 0;
        uint256[] memory stakedId = userStakes[_a];
        for (uint256 i = 0; i < stakedId.length; i++) {
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

    /// @notice   Allows stakers to claim their NFTs if they have won the raffle.
    function claimNFT() external {
        require(block.timestamp >= operationTime, "StakeNFT: Not claims time");
        address staker = _msgSender();
        ClaimInfo memory info = _claimInfo(staker);

        require(!info.hasClaimedNFT, "StakeNFT: has claimed");
        require(info.nftCount > 0, "StakeNFT: nothing to claim");

        hasClaimedNFT[staker] = true;

        Address.sendValue(payable(revenueWallet), info.transferAmount);

        bytes4 SELECTOR = bytes4(
            keccak256(bytes("nftcallermint(address,uint256)"))
        );

        (bool nftcallsuccess, bytes memory data) = nftAddress.call(
            abi.encodeWithSelector(SELECTOR, staker, info.nftCount)
        );

        require(
            nftcallsuccess && (data.length == 0 || abi.decode(data, (bool))),
            "Mint_NFT_Faliled"
        );

        emit Claim(staker, info.nftCount, info.transferAmount);
    }

    /// @notice   Allows stakers to receive a refund if they have not won the raffle.
    function refund() external {
        require(block.timestamp >= operationTime, "StakeNFT: Not refund time");
        address staker = _msgSender();
        ClaimInfo memory info = _claimInfo(staker);

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

    function getUserStakes(address _address)
        external
        view
        returns (Stake[] memory stakes)
    {
        uint256[] memory stakeId = userStakes[_address];
        stakes = new Stake[](stakeId.length);
        for (uint256 j = 0; j < stakeId.length; j++) {
            stakes[j] = stakeIdInfo[stakeId[j]];
        }
    }

    function getUserTickets()
        external
        view
        returns (uint256, uint256[] memory)
    {
        return _getUserTickets(msg.sender);
    }

    function _getUserTickets(address _addr)
        public
        view
        returns (uint256, uint256[] memory)
    {
        return (userStakes[_addr].length, userStakes[_addr]);
    }

    function getWhiStakeId() external view returns (uint256, uint256[] memory) {
        return (_whiteStakesId.length, _whiteStakesId);
    }

    function getPubStakeId() external view returns (uint256, uint256[] memory) {
        return (_publicStakesId.length, _publicStakesId);
    }

    function getRaffledId() external view returns (uint256[] memory) {
        require(
            block.timestamp >= raffleTime,
            "StakeNFT: Not check rewards time"
        );
        uint256[] memory raffleId = new uint256[](raffleCount);
        uint256 index;
        for (uint256 j = 0; j < _publicStakesId.length; j++) {
            uint256 stakeid = _publicStakesId[j];
            if (raffleWon[stakeid]) {
                raffleId[index] = stakeid;
                index++;
            }
        }
        return raffleId;
    }
}

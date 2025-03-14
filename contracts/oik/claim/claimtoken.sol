// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "solmate/src/utils/SafeTransferLib.sol";
import "solmate/src/tokens/ERC20.sol";

/**
 * @title ClaimToken
 * @dev Space Nation claim tokens
 * @author @SpaceNation
 * @notice Space Nation claim tokens
 */
contract ClaimToken is Ownable2Step {
    using ECDSA for bytes32;

    address public token;
    uint64 public thresholds;
    uint8 public decimals;
    uint8 public signumber;
    bool private checkthresholds;

    mapping(address => uint64) public nonces;
    mapping(address => bool) private signers;
    mapping(bytes => bool) private usedsignatures;
    mapping(address => bool) public isBlackListed;

    event Claim(
        address token,
        address sender,
        uint64 nonce,
        uint64 amount,
        bytes sig
    );
    event Transfer(address token, address[] player, uint64[] amount);

    error InvalidSignature();
    error InvalidArray();
    error DuplicatedSig();
    error InvalidAmount();

    constructor(
        address[] memory _signers,
        address _token,
        uint64 _thresholds,
        uint8 _decimals,
        uint8 _signumber
    ) {
        require(_token != address(0));
        require(_decimals < 19);
        require(_thresholds != 0);
        require(_signumber > 1);
        address signer;
        uint256 len = _signers.length;
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                signer = _signers[i];
                require(signer != address(0));
                signers[signer] = true;
            }
        }
        token = _token;
        thresholds = _thresholds;
        decimals = _decimals;
        signumber = _signumber;
    }

    /**
     * @notice Only the contract owner can airdrop tokens
     * @param wallet. The token wallet address.
     * @param players. Array of airdrop addresses.
     * @param amounts. Array of airdrop amounts corresponding to each address.
     */
    function transfer(
        address wallet,
        address[] calldata players,
        uint64[] calldata amounts
    ) external onlyOwner {
        uint256 len = players.length;
        if (amounts.length != len) {
            revert InvalidArray();
        }
        uint64 amount;
        address player;
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                amount = amounts[i];
                player = players[i];

                _transfer(wallet, player, amount);
            }
        }
        emit Transfer(token, players, amounts);
    }

    /**
     * @notice Users claim tokens through a valid signature.
     * @param wallet. The token wallet address.
     * @param amount. Amount of tokens claimed by the user.
     * @param sig. Signature generated off-chain based on the user's claim information.
     */
    function claim(
        address wallet,
        uint64 amount,
        bytes memory sig
    ) external {
        if (checkthresholds && amount > thresholds) {
            revert InvalidAmount();
        }
        address sender = _msgSender();
        assertValidCosign(sender, wallet, amount, sig);

        uint64 nonce = nonces[sender];
        ++nonces[sender];
        _transfer(wallet, sender, amount);
        emit Claim(token, sender, nonce, amount, sig);
    }

    /**
     * @notice Users claim tokens through some signatures.
     * @param wallet. The token wallet addresses.
     * @param amount. Amount of tokens claimed by the user.
     * @param sigs. Signatures generated off-chain based on the user's claim information.
     */
    function bigClaim(
        address wallet,
        uint64 amount,
        bytes[] calldata sigs
    ) external {
        if (signumber != sigs.length) {
            revert InvalidArray();
        }
        if (amount < thresholds) {
            revert InvalidAmount();
        }
        address sender = _msgSender();
        bytes memory sig;
        bytes memory siglog;
        uint64 nonce = nonces[sender];
        unchecked {
            for (uint256 i = 0; i < signumber; ++i) {
                sig = sigs[i];
                siglog = bytes.concat(siglog, sig);
                assertValidCosign(sender, wallet, amount, sig);
            }
        }

        ++nonces[sender];
        _transfer(wallet, sender, amount);
        emit Claim(token, sender, nonce, amount, siglog);
    }

    function _transfer(
        address from,
        address to,
        uint64 amount
    ) private {
        SafeTransferLib.safeTransferFrom(
            ERC20(token),
            from,
            to,
            amount * 10**decimals
        );
    }

    function _chainID() private view returns (uint64) {
        uint64 chainID;
        assembly {
            chainID := chainid()
        }
        return chainID;
    }

    function assertValidCosign(
        address sender,
        address wallet,
        uint64 amount,
        bytes memory sig
    ) private {
        require(!isBlackListed[sender]);
        if (usedsignatures[sig]) {
            revert DuplicatedSig();
        }
        bytes32 hash = keccak256(
            abi.encodePacked(
                amount,
                nonces[sender],
                _chainID(),
                token,
                sender,
                wallet,
                address(this)
            )
        );
        matchSigner(hash, sig);

        usedsignatures[sig] = true;
    }

    function matchSigner(bytes32 hash, bytes memory signature) private view {
        address _signer = hash.toEthSignedMessageHash().recover(signature);
        if (!signers[_signer]) {
            revert InvalidSignature();
        }
    }

    /**
     * @notice Only the contract owner address can configure the token address and decimals.
     * @param _token. Token  address.
     * @param _decimals. Token  decimals.
     */
    function setToken(address _token, uint8 _decimals) external onlyOwner {
        require(_token != address(0));
        require(_decimals < 19);
        token = _token;
        decimals = _decimals;
    }

    /**
     * @notice  Only the contract owner can add addresses to the blacklist.
     * @param _evilUsers. Token address.
     */
    function addBlackList(address[] calldata _evilUsers) external onlyOwner {
        uint256 len = _evilUsers.length;
        address evilUser;

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                evilUser = _evilUsers[i];
                isBlackListed[evilUser] = true;
            }
        }
    }

    /**
     * @notice  Only the contract owner can remove addresses from the blacklist.
     * @param _clearedUsers. Token address.
     */
    function removeBlackList(address[] calldata _clearedUsers)
    external
    onlyOwner
    {
        uint256 len = _clearedUsers.length;
        address clearUser;

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                clearUser = _clearedUsers[i];
                isBlackListed[clearUser] = false;
            }
        }
    }

    /**
     * @notice Only the contract owner can invalidate specific signatures.
     * @param signatures. Signatures.
     */
    function invalidateUnusedSignature(bytes[] calldata signatures)
    external
    onlyOwner
    {
        uint256 len = signatures.length;
        bytes memory evilSignature;

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                evilSignature = signatures[i];
                usedsignatures[evilSignature] = true;
            }
        }
    }

    /**
     * @notice Only the contract owner can increment a batch of users' nonce values to invalidate old signatures.
     * @param addrs. Player's addresses.
     */
    function invalidateUnusedNonce(address[] calldata addrs)
    external
    onlyOwner
    {
        uint256 len = addrs.length;
        address addr;

        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                addr = addrs[i];
                ++nonces[addr];
            }
        }
    }

    /**
     * @notice Sets signatures number.
     */
    function setSigNumber(uint8 _signumber) external onlyOwner {
        require(_signumber > 1);
        signumber = _signumber;
    }

    /**
     * @notice Sets threshold.
     */
    function setThresholds(uint64 _thresholds) external onlyOwner {
        require(_thresholds != 0);
        thresholds = _thresholds;
    }

    /**
     * @notice Sets threshold switch.
     */
    function setThresholds(bool flag) external onlyOwner {
        checkthresholds = flag;
    }

    /**
     * @notice Sets signer.
     */
    function setSigner(address _signer, bool flag) external onlyOwner {
        signers[_signer] = flag;
    }

    /**
     * @notice Refund of tokens mistakenly transferred.
     */
    function withdrawsToken(address to) external onlyOwner {
        uint256 balance = ERC20(token).balanceOf(address(this));
        SafeTransferLib.safeTransfer(ERC20(token), to, balance);
    }
}

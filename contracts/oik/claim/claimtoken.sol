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
    uint8 public decimals;
    uint64 private thresholds;
    bool private checkthresholds;

    mapping(address => bool) public tokens;
    mapping(address => uint64) public nonces;

    mapping(address => bool) private signers;
    mapping(bytes => bool) private signatures;

    event Claim(
        address token,
        address sender,
        uint64 nonce,
        uint64 amount,
        bytes sig
    );
    event Transfer(address token, address[] player, uint64[] amount);

    error InvalidSignaturesOrAmounts();
    error InvalidSignature();
    error InvalidArray();
    error InvalidToken();
    error DuplicatedSig();

    constructor(
        address[] memory _signers,
        address _token,
        uint64 _thresholds,
        uint8 _decimals
    ) {
        require(_token != address(0));
        address signer;
        uint256 len = _signers.length;
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                signer = _signers[i];
                require(signer != address(0));
                signers[signer] = true;
            }
        }
        tokens[_token] = true;
        thresholds = _thresholds;
        decimals = _decimals;
    }

    /**
     * @notice Only the contract owner address can configure the white list of the tokens address.
     * @param _tokens. Token  address.
     * @param flag. The status of each token.
     */
    function configWLtokens(address[] calldata _tokens, bool flag)
    external
    onlyOwner
    {
        uint256 len = _tokens.length;
        address token;
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                token = _tokens[i];
                require(token != address(0));
                tokens[token] = flag;
            }
        }
    }

    function setDecimals(uint8 _decimals) external onlyOwner {
        decimals = _decimals;
    }

    /**
     * @notice Only the contract owner can airdrop tokens
     * @param token. The token address.
     * @param wallet. The token wallet address.
     * @param players. Array of airdrop addresses.
     * @param amounts. Array of airdrop amounts corresponding to each address.
     */
    function transfer(
        address token,
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

                _transfer(token, wallet, player, amount);
            }
        }
        emit Transfer(token, players, amounts);
    }

    /**
     * @notice Users claim tokens through a valid signature.
     * @param amount. Amount of tokens claimed by the user.
     * @param wallet. The token wallet address.
     * @param token. The token address.
     * @param sig. Signature generated off-chain based on the user's claim information.
     */
    function claim(
        address token,
        address wallet,
        uint64 amount,
        bytes memory sig
    ) external {
        if (checkthresholds && amount > thresholds) {
            revert();
        }
        address sender = _msgSender();
        assertValidCosign(token, sender, wallet, amount, sig);

        uint64 nonce = nonces[sender];
        ++nonces[sender];
        _transfer(token, wallet, sender, amount);
        emit Claim(token, sender, nonce, amount, sig);
    }

    /**
     * @notice Users claim tokens through some signatures.
     * @param amount. Amount of tokens claimed by the user.
     * @param wallet. The token wallet addresses.
     * @param token. The token address.
     * @param sigs. Signatures generated off-chain based on the user's claim information.
     */
    function bigClaim(
        address token,
        address wallet,
        uint64 amount,
        bytes[] calldata sigs
    ) external {
        uint256 len = sigs.length;
        if (len < 2 || amount < thresholds) {
            revert InvalidSignaturesOrAmounts();
        }
        address sender = _msgSender();
        bytes memory sig;
        bytes memory siglog;
        uint64 nonce = nonces[sender];
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                sig = sigs[i];
                siglog = bytes.concat(siglog, sig);
                assertValidCosign(token, sender, wallet, amount, sig);
            }
        }

        ++nonces[sender];
        _transfer(token, wallet, sender, amount);
        emit Claim(token, sender, nonce, amount, siglog);
    }

    function _transfer(
        address token,
        address from,
        address to,
        uint64 amount
    ) private {
        if (!tokens[token]) {
            revert InvalidToken();
        }
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
        address token,
        address sender,
        address wallet,
        uint64 amount,
        bytes memory sig
    ) private {
        if (signatures[sig]) {
            revert DuplicatedSig();
        }

        uint64 nonce = nonces[sender];
        bytes32 hash = keccak256(
            abi.encodePacked(
                amount,
                nonce,
                _chainID(),
                token,
                sender,
                wallet,
                address(this)
            )
        );
        matchSigner(hash, sig);

        signatures[sig] = true;
    }

    function matchSigner(bytes32 hash, bytes memory signature) private view {
        address _signer = hash.toEthSignedMessageHash().recover(signature);
        if (!signers[_signer]) {
            revert InvalidSignature();
        }
    }

    /**
     * @notice Sets threshold.
     */
    function setThresholds(uint64 _thresholds, bool flag) external onlyOwner {
        require(_thresholds != 0);
        thresholds = _thresholds;
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
    function withdrawsToken(address token, address to) external onlyOwner {
        uint256 balance = ERC20(token).balanceOf(address(this));
        SafeTransferLib.safeTransfer(ERC20(token), to, balance);
    }
}
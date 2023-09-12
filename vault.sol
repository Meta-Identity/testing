// SPDX-License-Identifier: MIT

// Polykick Vault V1

pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract polykickVault {
    address public owner;

    uint256 private buyerOperationID;
    uint256 private sellerOperationID;
    uint256 public constant oneMonth =
        150; /*days*/

    bool vaultPaused = false;

    /* @dev: Check if contract owner */
    modifier onlyOwner() {
        require(msg.sender == owner, "Not Owner!");
        _;
    }

    /* @dev: Check if ILO contract */
    modifier onlyILO() {
        require(isILO[msg.sender], "Sender is not ILO contract");

        _;
    }

    struct Vault {
        uint256 operationID;
        address owner;
        IERC20 token;
        uint256 tokenAmount;
        uint256 unclaimed;
        uint256 claimed;
        uint256 timeLock;
        bool firstClaim;
    }

    struct BuyerInfo {
        uint256 lockedAmount;
        uint256 timeLeftForFirstClaim;
        uint256 timeLeftForAllClaims;
    }

    mapping(address => bool) public isILO;
    mapping(uint256 => Vault) public buyers;
    mapping(uint256 => Vault) public sellers;
    mapping(address => uint256[]) public buyerOperationIDs;
    mapping(address => uint256[]) public sellerOperationIDs;
    mapping(IERC20 => uint256) public tradingStart;

    event buyerVaultDeposit(
        uint256 operationID,
        address buyer,
        IERC20 token,
        uint256 amount,
        uint256 daysLocked
    );
    event sellerVaultDeposit(
        uint256 operationID,
        address seller,
        IERC20 token,
        uint256 amount
    );
    event iloAdded(address indexed newILO);
    event ChangeOwner(address newOwner);
    event emergencyWithdrawl(IERC20 Token, address To, uint256 Amount);
    event sellerVaultRemoved(uint256 operationID, address seller, IERC20 token);
    event buyerVaultRemoved(uint256 operationID, address buyer, IERC20 token);

    constructor() {
        owner = msg.sender;
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0x0), "Zero address");
        emit ChangeOwner(_newOwner);
        owner = _newOwner;
    }

    function setPauseVault(bool _status) external onlyOwner {
        vaultPaused = _status;
    }

    function addILO(address _ILO) external onlyOwner {
        require(_ILO != address(0), "Address zero!");
        isILO[_ILO] = true;
        emit iloAdded(_ILO);
    }

    function tradingStarted(IERC20 _token) external onlyOwner {
        require(tradingStart[_token] == 0, "Trading has started");
        tradingStart[_token] = block.timestamp;
    }

    function depositToBuyerVault(
        address _buyer,
        IERC20 _token,
        uint256 _amount,
        uint256 _lockDays
    ) external onlyILO {
        buyerOperationID++;
        buyerOperationIDs[_buyer].push(buyerOperationID);
        buyers[buyerOperationID] = Vault(
            buyerOperationID,
            _buyer,
            _token,
            _amount, // tokenAmount
            _amount, // unclaimed
            0, // claimed
            (300), /* * 1 days)*/
            false
        );
        emit buyerVaultDeposit(buyerOperationID, _buyer, _token, _amount, _lockDays);
    }

    function depositToSellerVault(
        address _seller,
        IERC20 _token,
        uint256 _amount
    ) external onlyILO {
        sellerOperationID++;
        sellerOperationIDs[_seller].push(sellerOperationID);
        sellers[sellerOperationID] = Vault(
            sellerOperationID,
            _seller,
            _token,
            _amount,
            _amount,
            0,
            0,
            false
        );
        emit sellerVaultDeposit(sellerOperationID, _seller, _token, _amount);
    }

    function withdrawFromBuyerVault(address _buyer, IERC20 _token) external {
        require(!vaultPaused, "Vault withdraw is paused for maintenance");
        uint256 startOfLock = tradingStart[_token];
        require(startOfLock != 0, "Trading start not set for token");
        uint256 buyerLock = 0;
        uint256[] memory ids = buyerOperationIDs[_buyer];
        for (uint256 i = 0; i < ids.length; i++) {
            Vault storage vault = buyers[ids[i]];
            buyerLock = vault.timeLock + startOfLock;
            if (vault.claimed == vault.tokenAmount) {
                revert("All buyer tokens claimed");
            }
            if (vault.token == _token) {
                require(
                    block.timestamp >= buyerLock - oneMonth,
                    "First claim not due!"
                );

                uint256 withdrawableAmount;
                if (block.timestamp >= buyerLock) {
                    // If the full time lock has passed, allow the owner to withdraw all tokens
                    withdrawableAmount = vault.unclaimed;
                } else {
                    require(!vault.firstClaim, "Second claim not due!");
                    // If only half the time lock has passed, allow the owner to withdraw half the tokens
                    withdrawableAmount = vault.unclaimed / 2;
                    vault.firstClaim = true;
                }

                require(
                    vault.token.balanceOf(address(this)) >= withdrawableAmount,
                    "Not enough tokens in contract!"
                );

                vault.unclaimed -= withdrawableAmount;
                vault.claimed += withdrawableAmount;
                vault.token.transfer(vault.owner, withdrawableAmount);

                return;
            }
        }
        revert("No vault found for this token!");
    }

    function withdrawFromSellerVault(
        IERC20 _token,
        address _to,
        uint256 _amount
    ) external onlyOwner {
        require(!vaultPaused, "Vault withdraw is paused for maintenance");
        uint256[] memory ids = sellerOperationIDs[_to];
        for (uint256 i = 0; i < ids.length; i++) {
            Vault storage vault = sellers[ids[i]];
            if (vault.claimed == vault.tokenAmount) {
                revert("All seller tokens claimed");
            }
            if (vault.token == _token) {
                require(
                    vault.token.balanceOf(address(this)) >= _amount,
                    "Not enough tokens in contract!"
                );

                vault.unclaimed -= _amount;
                vault.claimed += _amount;
                vault.token.transfer(vault.owner, _amount);
                return;
            }
        }
        revert("No vault found for this token!");
    }

    // View address vault per operation ID
    function getBuyerVaults(address _address)
        public
        view
        returns (Vault[] memory)
    {
        uint256[] memory ids = buyerOperationIDs[_address];
        Vault[] memory vaults = new Vault[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (buyers[id].owner == _address) {
                vaults[i] = buyers[id];
            } else if (sellers[id].owner == _address) {
                vaults[i] = sellers[id];
            }
        }

        return vaults;
    }

    // View address vault per operation ID
    function getSellerVaults(address _address)
        public
        view
        returns (Vault[] memory)
    {
        uint256[] memory ids = sellerOperationIDs[_address];
        Vault[] memory vaults = new Vault[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            if (buyers[id].owner == _address) {
                vaults[i] = buyers[id];
            } else if (sellers[id].owner == _address) {
                vaults[i] = sellers[id];
            }
        }

        return vaults;
    }

    function _getInfo(uint256 _tokenAmount)
        internal
        pure
        returns (uint256 _amount, string memory _status)
    {
        _amount = _tokenAmount;
        _status = "Token trading not started";
        return (_amount, _status);
    }

    function getBuyerInfo(address _buyer, IERC20 _token)
        public
        view
        returns (BuyerInfo memory)
    {
        uint256[] memory ids = buyerOperationIDs[_buyer];
        BuyerInfo memory buyerInfo;
        for (uint256 i = 0; i < ids.length; i++) {
            Vault storage vault = buyers[ids[i]];
            if (vault.token == _token) {
                uint256 lockTime = tradingStart[_token] + vault.timeLock;
                buyerInfo.lockedAmount = vault.unclaimed;

                if (tradingStart[_token] == 0) {
                    _getInfo(vault.unclaimed);
                }

                // Calculate time left for first and full claim
                if (block.timestamp < lockTime - oneMonth) {
                    buyerInfo.timeLeftForFirstClaim =
                        lockTime -
                        oneMonth -
                        block.timestamp;
                } else {
                    buyerInfo.timeLeftForFirstClaim = 0;
                }

                if (block.timestamp < lockTime) {
                    buyerInfo.timeLeftForAllClaims = lockTime - block.timestamp;
                } else {
                    buyerInfo.timeLeftForAllClaims = 0;
                }

                return buyerInfo;
            }
        }
        revert("No vault found for this buyer and token");
    }

    function emergencyWithdraw(
        IERC20 _token,
        address[] memory _to,
        uint256[] memory _amount
    ) external onlyOwner {
        for (uint256 i = 0; i < _to.length; i++) {
            emit emergencyWithdrawl(_token, _to[i], _amount[i]);
            _token.transfer(_to[i], _amount[i]);
        }
    }

    function removeSeller(uint256 _operationID) external onlyOwner {
        Vault storage vault = sellers[_operationID];

        require(vault.owner != address(0), "Seller vault does not exist!");


        // Emit the event before removing to track details
        emit sellerVaultRemoved(_operationID, vault.owner, vault.token);

        // Delete seller vault
        delete sellers[_operationID];
    }

    function removeBuyer(uint256 _operationID) external onlyOwner {
        Vault storage vault = buyers[_operationID];

        require(vault.owner != address(0), "Buyer vault does not exist!");

        // Emit the event before removing to track details
        emit buyerVaultRemoved(_operationID, vault.owner, vault.token);

        // Delete buyer vault
        delete buyers[_operationID];
    }

    function getBuyerOperationIDs(address _buyer) external view returns (uint256[] memory) {
        return buyerOperationIDs[_buyer];
    }

    function getSellerOperationIDs(address _seller) external view returns (uint256[] memory) {
        return sellerOperationIDs[_seller];
    }

}

                /*********************************************************
                    Proudly Developed by Jaafar Krayem Copyright 2023
                **********************************************************/

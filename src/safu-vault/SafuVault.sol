// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "forge-std/console.sol";


/// @dev interface for interacting with the strategy
interface IStrategy {
    function want() external view returns (IERC20);
    function beforeDeposit() external;
    function deposit() external;
    function withdraw(uint256) external;
    function balanceOf() external view returns (uint256);
}

/// @dev safu yield vault with automated strategy
contract SafuVault is ERC20, Ownable, ReentrancyGuard {

    using SafeERC20 for IERC20;
    
    // The strategy currently in use by the vault.
    IStrategy public strategy;

    constructor (
        IStrategy _strategy,
        string memory _name,
        string memory _symbol
    ) ERC20 (
        _name,
        _symbol
    ) {
        strategy = IStrategy(_strategy);
    }

    /// @dev token required as input for this strategy
    function want() public view returns (IERC20) {
        return IERC20(strategy.want());
    }

    /// @dev calculates amount of funds available to put to work in strategy
    function available() public view returns (uint256) {
        return want().balanceOf(address(this));
    }

    /// @dev calculates total underlying value of tokens held by system (vault+strategy)
    function balance() public view returns (uint256) {
        return available()+strategy.balanceOf();
    }

    /// @dev calls deposit() with all the sender's funds
    function depositAll() external {
        deposit(want().balanceOf(msg.sender));
    }
     
    /// @dev entrypoint of funds into the system
    /// @dev people deposit with this function into the vault
    function deposit(uint256 _amount) public nonReentrant {
        strategy.beforeDeposit();
        // balanceOf want in Vault + Strategy
        uint256 _pool = balance();
        // move want from user to Vault
        want().safeTransferFrom(msg.sender, address(this), _amount);
        // move all want in the Vault to Strategy
        earn();
        uint256 _after = balance();
        _amount = _after - _pool; // Additional check for deflationary tokens
        console.log("amount: %s", _amount);
        uint256 shares;
        if (totalSupply() == 0) {
            shares = _amount;
        } else {
            shares = (_amount * totalSupply()) / (_pool);
        }
        _mint(msg.sender, shares);
    }

    /// @dev sends funds to strategy to put them to work, by calling deposit() function
    function earn() public {
        uint256 _bal = available();
        want().safeTransfer(address(strategy), _bal);
        strategy.deposit();
    }

    /// @dev helper function to call withdraw() with all sender's funds
    function withdrawAll() external {
        withdraw(balanceOf(msg.sender));
    }

    /// @dev allows user to withdraw specified funds
    function withdraw(uint256 _shares) public {
        // want balance in Vault + Strategy
        uint256 r = (balance() * _shares) / (totalSupply());
        _burn(msg.sender, _shares); // will revert if _shares > what user has

        uint256 b = want().balanceOf(address(this)); // check vault balance

        if (b < r) { // withdraw any extra required funds from strategy
            uint256 _withdraw = r - b;
            strategy.withdraw(_withdraw);
            uint256 _after = want().balanceOf(address(this));
            uint256 _diff = _after - b;
            if (_diff < _withdraw) {
                r = b + _diff;
            }
        }

        want().safeTransfer(msg.sender, r);
    }

    /// @dev deposit funds into the system for other user
    function depositFor(
        address token, 
        uint256 _amount, 
        address user
    ) public {
        strategy.beforeDeposit();
        // want in Vault + Strategy
        uint256 _pool = balance();
        console.log("pool: %s", _pool);
        IERC20(token).safeTransferFrom(msg.sender, address(this), _amount);
        // move all want in the Vault to Strategy
        earn();
        uint256 _after = balance();
        console.log("after: %s", _after);
        _amount = _after - _pool; // Additional check for deflationary tokens
        console.log("amount: %s", _amount);
        uint256 shares;
        if (totalSupply() == 0) {
            shares = _amount;
        } else {
            shares = (_amount * totalSupply()) / (_pool);
        }  
        console.log("shares: %s", shares);
        _mint(user, shares);
    }

}
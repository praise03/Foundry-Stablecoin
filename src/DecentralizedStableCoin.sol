//SPDX_License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
/*
 * @title DecentralizedStableCoin
 * @author Praise
 * Collateral: Exogenous (Collateralized (minted by depositing) by an external entity; ETH & BTC)
 * Minting: Algorithmic (A set of decentralized instructions govern its supply & value)
 * Relative Stability: Pegged to USD (Using chainlink price feeds to fetch $usd price)
 
 * This contract is an ERC20 implementation of our stablecoin governed by the DSCEngine.sol
*/
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DSCoin__MustBeMoreThanZero();
    error DSCoin__BurnAmountExceedsBalance();
    error DSCoin__MintToZeroAddress();
    
    constructor()ERC20("DecentralizedStableCoin", "DSC") {

    }

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0 ) revert DSCoin__MustBeMoreThanZero();
        if (balance < _amount) revert DSCoin__BurnAmountExceedsBalance();

        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) revert DSCoin__MintToZeroAddress();
        if (_amount <= 0) revert DSCoin__MustBeMoreThanZero();
        
        _mint(_to, _amount);
        return true;

    }
}
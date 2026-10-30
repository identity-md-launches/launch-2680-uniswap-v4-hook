// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TaxToken is MockERC20 {
    constructor() MockERC20("Tax", "TAX") {}

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && amount > 100) {
            super._update(from, address(0), amount / 100);
            amount -= amount / 100;
        }
        super._update(from, to, amount);
    }
}

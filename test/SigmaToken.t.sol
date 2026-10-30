// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SigmaToken} from "../src/SigmaToken.sol";

contract SigmaTokenTest is Test {
    SigmaToken token;

    function setUp() public {
        token = new SigmaToken();
    }

    function test_fixedSupplyAndMetadata() public view {
        assertEq(token.name(), "SigmaHook");
        assertEq(token.symbol(), "SHK");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function testFuzz_transferAndAllowance(uint256 amount) public {
        amount = bound(amount, 1, token.totalSupply());
        address receiver = makeAddr("receiver");
        address spender = makeAddr("spender");
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(address(this), receiver, amount);
        assertEq(token.balanceOf(receiver), amount);
        assertEq(token.balanceOf(address(this)), token.totalSupply() - amount);
        assertEq(token.allowance(address(this), spender), 0);
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(receiver, spender, 1);
    }

    function test_noAdminOrAdditionalMint() public {
        bytes4[5] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("initialize(address)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], address(this), 1));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}

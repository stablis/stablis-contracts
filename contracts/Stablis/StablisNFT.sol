// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract StablisNFT is ERC721Enumerable {

    address immutable public minter;
    uint256 constant public maxSupply = 2500;

    uint256 private tokenIdCounter;

    constructor(address _minter) ERC721('Stablis Staking Boost NFT', 'SSB') {
        minter = _minter == address(0) ? msg.sender : _minter;
    }

    function mint(address _to) external {
        _mint(_to);
    }

    function bulkMint(address[] calldata _to) external {
        for (uint256 i = 0; i < _to.length; i++) {
            _mint(_to[i]);
        }
    }

    function _mint(address _to) internal {
        require(msg.sender == minter, 'StablisNFT: Not minter');
        require(tokenIdCounter < maxSupply, 'StablisNFT: Max supply reached');

        uint256 tokenId = tokenIdCounter;
        unchecked {
            tokenIdCounter++;
        }
        _safeMint(_to, tokenId);
    }

    function _baseURI() internal pure override returns (string memory) {
        return "https://nft.stablis.finance/";
    }
}

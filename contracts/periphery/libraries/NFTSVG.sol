// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.6;
pragma abicoder v2;

import '@openzeppelin/contracts/utils/Strings.sol';

/// @title NFTSVG
/// @notice Provides a function for generating an SVG associated with a CL NFT
library NFTSVG {
  using Strings for uint256;

  struct SVGParams {
    string quoteTokenSymbol;
    string baseTokenSymbol;
    address quoteTokenAddress;
    address baseTokenAddress;
    uint256 tokenId;
    string priceLower;
    string priceUpper;
    int24 tickSpacing;
    uint256 chainId;
  }

  /// @dev Base URI token logos are fetched from, keyed by chain id and EIP-55 checksummed token address
  string internal constant LOGO_BASE_URI = 'https://assets.smold.app/token/';

  function generateSVG(SVGParams memory params) public pure returns (string memory svg) {
    return string(
      abi.encodePacked(
        '<svg width="400" height="400" viewBox="0 0 400 400" fill="none" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">\n',
        '<rect width="400" height="400" fill="white"/>\n',
        '<rect width="400" height="400" fill="#090E1F"/>\n',
        '<rect x="61.5" y="109.5" width="277" height="181" rx="90.5" stroke="url(#ringGrad)" stroke-width="3"/>\n',
        generateArt(params),
        generateText(params),
        '<path d="M368 20L377.75 20.0004L380 22.2504L380 32" stroke="#EAEAEC" stroke-width="1.5" stroke-miterlimit="16"/>\n\n',
        generateSVGDefs(),
        '</svg>\n'
      )
    );
  }

  /// @dev `{LOGO_BASE_URI}{chainId}/{checksummedTokenAddress}/logo-128.png`
  function logoURI(address token, uint256 chainId) internal pure returns (string memory) {
    // smoldapp keys token assets by the EIP-55 checksummed address, so the casing must match for the logo to resolve.
    return string(abi.encodePacked(LOGO_BASE_URI, chainId.toString(), '/', toChecksumString(token), '/logo-128.png'));
  }

  /// @dev EIP-55 checksummed hex string of an address, `0x` prefixed
  function toChecksumString(address addr) internal pure returns (string memory) {
    bytes memory lower = new bytes(40);
    bytes memory hexChars = '0123456789abcdef';
    uint160 value = uint160(addr);
    for (uint256 i = 40; i > 0; i--) {
      lower[i - 1] = hexChars[value & 0xf];
      value >>= 4;
    }
    bytes32 hash = keccak256(lower);
    bytes memory checksummed = new bytes(42);
    checksummed[0] = '0';
    checksummed[1] = 'x';
    for (uint256 i = 0; i < 40; i++) {
      uint8 nibble = uint8(hash[i / 2]);
      nibble = i % 2 == 0 ? nibble >> 4 : nibble & 0xf;
      bytes1 char = lower[i];
      // letters a-f are uppercased when the matching hash nibble is 8 or above
      if (char >= 'a' && nibble >= 8) char = bytes1(uint8(char) - 32);
      checksummed[i + 2] = char;
    }
    return string(checksummed);
  }

  /// @dev Escapes `&`, `<`, `>`, `"` and `'` so a token symbol cannot inject markup into the SVG
  function escapeHTML(string memory input) internal pure returns (string memory) {
    bytes memory raw = bytes(input);
    bytes memory escaped;
    for (uint256 i = 0; i < raw.length; i++) {
      bytes1 char = raw[i];
      if (char == '&') escaped = abi.encodePacked(escaped, '&amp;');
      else if (char == '<') escaped = abi.encodePacked(escaped, '&lt;');
      else if (char == '>') escaped = abi.encodePacked(escaped, '&gt;');
      else if (char == '"') escaped = abi.encodePacked(escaped, '&quot;');
      else if (char == "'") escaped = abi.encodePacked(escaped, '&#39;');
      else escaped = abi.encodePacked(escaped, char);
    }
    return string(escaped);
  }

  /// @dev Quote token on the left, base token on the right, each logo layered over a placeholder shown when the
  ///      logo is missing
  function generateArt(SVGParams memory params) private pure returns (string memory svg) {
    string memory quoteLogo = logoURI(params.quoteTokenAddress, params.chainId);
    string memory baseLogo = logoURI(params.baseTokenAddress, params.chainId);
    svg = string(
      abi.encodePacked(
        '<path opacity="0.55" d="M152 272C191.764 272 224 239.764 224 200C224 160.236 191.764 128 152 128C112.236 128 80 160.236 80 200C80 239.764 112.236 272 152 272Z" fill="#22294B"/>\n',
        '<path d="M152 176.6L159.446 192.554L175.4 200L159.446 207.446L152 223.4L144.554 207.446L128.6 200L144.554 192.554L152 176.6Z" fill="#8C9FFF"/>\n',
        '<image x="80" y="128" width="144" height="144" clip-path="url(#quoteClip)" href="',
        quoteLogo,
        '"/>\n',
        '<path opacity="0.55" d="M248 272C287.764 272 320 239.764 320 200C320 160.236 287.764 128 248 128C208.236 128 176 160.236 176 200C176 239.764 208.236 272 248 272Z" fill="#22294B"/>\n',
        '<path d="M248 176.6L255.446 192.554L271.4 200L255.446 207.446L248 223.4L240.554 207.446L224.6 200L240.554 192.554L248 176.6Z" fill="#8C9FFF"/>\n',
        '<image x="176" y="128" width="144" height="144" clip-path="url(#baseClip)" href="',
        baseLogo,
        '"/>\n',
        '<path d="M32 380L22.25 380L20 377.75L20 368" stroke="#EAEAEC" stroke-width="1.5" stroke-miterlimit="16"/>\n',
        '<path d="M380 368L380 377.75L377.75 380L368 380" stroke="#EAEAEC" stroke-width="1.5" stroke-miterlimit="16"/>\n'
      )
    );
  }

  function generateText(SVGParams memory params) private pure returns (string memory svg) {
    string memory pool = string(
      abi.encodePacked(
        escapeHTML(params.quoteTokenSymbol),
        '/',
        escapeHTML(params.baseTokenSymbol),
        ' CL ',
        tickToString(params.tickSpacing)
      )
    );
    string memory range =
      string(abi.encodePacked(escapeHTML(params.priceLower), '&#8211;', escapeHTML(params.priceUpper)));
    svg = string(
      abi.encodePacked(
        '<g font-family="\'Roobert Mono\', ui-monospace, \'SF Mono\', Menlo, monospace" font-size="10" letter-spacing="0.2" fill="#EAEAEC">\n',
        textLine('32', 'POOL:', pool),
        textLine('48', 'RANGE:', range),
        textLine('64', 'ID:', string(abi.encodePacked('#', params.tokenId.toString()))),
        '</g>\n'
      )
    );
  }

  function textLine(string memory y, string memory label, string memory value) private pure returns (string memory) {
    return string(
      abi.encodePacked(
        '<text x="20" y="', y, '"><tspan fill-opacity="0.5">', label, '</tspan><tspan> ', value, '</tspan></text>\n'
      )
    );
  }

  function generateSVGDefs() private pure returns (string memory svg) {
    svg = string(
      abi.encodePacked(
        '<defs>\n',
        '<clipPath id="quoteClip"><circle cx="152" cy="200" r="72"/></clipPath>\n',
        '<clipPath id="baseClip"><circle cx="248" cy="200" r="72"/></clipPath>\n',
        '<linearGradient id="ringGrad" gradientUnits="objectBoundingBox" x1="0" y1="0" x2="1" y2="1">\n',
        '<stop offset="0" stop-color="#0B1233"/>\n',
        '<stop offset="0.20" stop-color="#1446EA"/>\n',
        '<stop offset="0.45" stop-color="#FF2D12"/>\n',
        '<stop offset="0.62" stop-color="#FF6A3D"/>\n',
        '<stop offset="0.80" stop-color="#DCEBFF"/>\n',
        '<stop offset="1" stop-color="#0B1233"/>\n',
        '<animateTransform attributeName="gradientTransform" type="rotate" from="0 0.5 0.5" to="360 0.5 0.5" dur="7s" repeatCount="indefinite"/>\n',
        '</linearGradient>\n',
        '</defs>\n'
      )
    );
  }

  function tickToString(int24 tick) private pure returns (string memory) {
    string memory sign = '';
    if (tick < 0) {
      tick = tick * -1;
      sign = '-';
    }
    return string(abi.encodePacked(sign, uint256(tick).toString()));
  }
}

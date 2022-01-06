// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.7.5;

import "./IERC20.sol";

// Old wsOHM interface
interface IwsSAPI is IERC20 {
  function wrap(uint256 _amount) external returns (uint256);

  function unwrap(uint256 _amount) external returns (uint256);

  function wSAPITosSAPI(uint256 _amount) external view returns (uint256);

  function sSAPITowSAPI(uint256 _amount) external view returns (uint256);
}

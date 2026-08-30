pragma solidity ^0.7.6;
pragma abicoder v2;

struct Users {
  // CLFactory owner / general purpose admin
  address payable owner;
  // CLFactory fee manager
  address payable feeManager;
  // CLFactory discount registry manager
  address payable discountRegistryManager;
  // CLFactory cl pool tape manager
  address payable clPoolTapeManager;
  // User, used to initiate calls
  address payable alice;
  // User, used as recipient
  address payable bob;
  // User, used as malicious user
  address payable charlie;
  // User, used as referral recipient
  address payable referral;
}

// Based from https://github.com/starcoinorg/starcoin-framework/blob/main/sources/Dao.move
module suitears::dao {
  use std::option::{Self, Option};

  use sui::event::emit;
  use sui::coin::{Self, Coin};
  use sui::clock::{Self, Clock};
  use sui::object::{Self, ID, UID};
  use sui::balance::{Self, Balance};
  use sui::types::is_one_time_witness;
  use sui::tx_context::{Self, TxContext};

  use suitears::fixed_point_wad::{wad, wad_div_down};

  /// Proposal state
  const PENDING: u8 = 1;
  const ACTIVE: u8 = 2;
  const DEFEATED: u8 = 3;
  const AGREED: u8 = 4;
  const QUEUED: u8 = 5;
  const EXECUTABLE: u8 = 6;
  const EXTRACTED: u8 = 7;

  const EInvalidOTW: u64 = 0;
  const EInvalidQuorumRate: u64 = 1;
  const EInvalidVotingDelay: u64 = 2;
  const EInvalidVotingPeriod: u64 = 3;
  const EInvalidMinActionDelay: u64 = 4;
  const EActionDelayTooSmall: u64 = 5;
  const EInvalidMinQuorumVotes: u64 = 6;
  const EMinQuorumVotesTooSmall: u64 = 7;
  const EProposalMustBeActive: u64 = 8;
  const ECannotVoteWithZeroCoinValue: u64 = 9;
  const ECannotUnstakeFromAnActiveProposal: u64 = 10;
  const EVoteAndProposalIdMismatch: u64 = 11;
  const ECannotExecuteThisProposal: u64 = 12;
  const ETooEarlyToExecute: u64 = 13;

  // Generic Struct represents null/undefined
  struct Nothing has drop, copy, store {}

  struct DaoConfig has key, store {
    id: UID,
    voting_delay: Option<u64>,
    voting_period: Option<u64>,
    voting_quorum_rate: Option<u128>,
    min_action_delay: Option<u64>,
    min_quorum_votes: Option<u64>    
  }

  struct DAO<phantom OTW, phantom CoinType> has key, store {
    id: UID,
    /// after proposal created, how long use should wait before he can vote (in milliseconds)
    voting_delay: u64,
    /// how long the voting window is (in milliseconds).
    voting_period: u64,
    /// the quorum rate to agree on the proposal.
    /// if 50% votes needed, then the voting_quorum_rate should be 50.
    /// it should between (0, 100].
    voting_quorum_rate: u128,
    /// how long the proposal should wait before it can be executed (in milliseconds).
    min_action_delay: u64,
    min_quorum_votes: u64
  }

  struct Proposal<phantom DAOWitness: drop, phantom ModuleWitness: drop, phantom CoinType, T: store> has key, store {
    id: UID,
    proposer: address,
    start_time: u64,
    end_time: u64,
    for_votes: u64,
    against_votes: u64,
    eta: u64,
    action_delay: u64,
    quorum_votes: u64,
    voting_quorum_rate: u128, 
    payload: Option<T>
  }

  struct Vote<phantom DAOWitness: drop, phantom ModuleWitness: drop, phantom CoinType, phantom T> has  key, store {
    id: UID,
    balance: Balance<CoinType>,
    proposal_id: ID,
    end_time: u64,
    agree: bool
  } 

  // Hot Potato do not add abilities
  struct Action<phantom DAOWitness: drop, phantom ModuleWitness: drop, phantom CoinType, T> {
    payload: T
  }

  // Events

  struct CreateDAO<phantom OTW, phantom CoinType> has copy, drop {
    dao_id: ID,
    creator: address,
    voting_delay: u64, 
    voting_period: u64, 
    voting_quorum_rate: u128, 
    min_action_delay: u64, 
    min_quorum_votes: u64
  }

  struct UpdateDAO<phantom OTW, phantom CoinType> has copy, drop {
    dao_id: ID,
    voting_delay: u64, 
    voting_period: u64, 
    voting_quorum_rate: u128, 
    min_action_delay: u64, 
    min_quorum_votes: u64
  }

  struct NewProposal<phantom DAOWitness, phantom ModuleWitness, phantom CoinType, phantom T> has copy, drop {
    proposal_id: ID,
    proposer: address,
  }

  struct CastVote<phantom DAOWitness, phantom ModuleWitness, phantom CoinType, phantom T> has copy, drop {
    voter: address, 
    proposal_id: ID,
    agree: bool,
    end_time: u64,
    value: u64
  }

  struct ChangeVote<phantom DAOWitness, phantom ModuleWitness, phantom CoinType, phantom T> has copy, drop {
    voter: address, 
    proposal_id: ID,
    vote_id: ID,
    agree: bool,
    end_time: u64,
    value: u64
  }

  struct RevokeVote<phantom DAOWitness, phantom ModuleWitness, phantom CoinType, phantom T> has copy, drop {
    voter: address, 
    proposal_id: ID,
    agree: bool,
    value: u64
  }

  struct UnstakeVote<phantom DAOWitness, phantom ModuleWitness, phantom CoinType, phantom T> has copy, drop {
    voter: address, 
    proposal_id: ID,
    agree: bool,
    value: u64
  }

  public fun create<OTW: drop, CoinType>(
    otw: OTW, 
    voting_delay: u64, 
    voting_period: u64, 
    voting_quorum_rate: u128, 
    min_action_delay: u64, 
    min_quorum_votes: u64,
    ctx: &mut TxContext
  ): DAO<OTW, CoinType> {
    assert!(is_one_time_witness(&otw), EInvalidOTW);
    assert!(100 * wad() >= voting_quorum_rate && voting_quorum_rate != 0, EInvalidQuorumRate);
    assert!(voting_delay != 0, EInvalidVotingDelay);
    assert!(voting_period != 0, EInvalidVotingPeriod);
    assert!(min_action_delay != 0, EInvalidMinActionDelay);
    assert!(min_quorum_votes != 0, EInvalidMinQuorumVotes);

    let dao = DAO {
      id: object::new(ctx),
      voting_delay,
      voting_period,
      voting_quorum_rate,
      min_action_delay,
      min_quorum_votes
    };

    emit(
      CreateDAO<OTW, CoinType> {
        dao_id: object::id(&dao),
        creator: tx_context::sender(ctx),
        voting_delay,
        voting_period,
        voting_quorum_rate,
        min_action_delay,
        min_quorum_votes
      }
    );

    dao
  }

  public fun propose_with_action<DAOWitness: drop, ModuleWitness: drop, CoinType, T: store>(
    dao: &mut DAO<DAOWitness, CoinType>,
    c: &Clock,
    payload: T,
    action_delay: u64,
    min_quorum_votes: u64,
    ctx: &mut TxContext
  ): Proposal<DAOWitness, ModuleWitness,  CoinType, T> {
   propose(dao, c, option::some(payload), action_delay, min_quorum_votes, ctx)
  }

  public fun propose_without_action<DAOWitness: drop, CoinType>(
    dao: &mut DAO<DAOWitness, CoinType>,
    c: &Clock,
    action_delay: u64,
    min_quorum_votes: u64,
    ctx: &mut TxContext
  ): Proposal<DAOWitness, Nothing,  CoinType, Nothing> {
   propose(dao, c, option::none(), action_delay, min_quorum_votes, ctx)
  }

  public fun cast_vote<DAOWitness: drop, ModuleWitness: drop, CoinType, T: store>(
    proposal: &mut Proposal<DAOWitness, ModuleWitness,  CoinType, T>,
    c: &Clock,
    stake: Coin<CoinType>,
    agree: bool,
    ctx: &mut TxContext
  ): Vote<DAOWitness, ModuleWitness,  CoinType, T> {
    assert!(get_proposal_state(proposal, clock::timestamp_ms(c)) == ACTIVE, EProposalMustBeActive);

    let value = coin::value(&stake);
    assert!(value != 0, ECannotVoteWithZeroCoinValue);

    if (agree) proposal.for_votes = proposal.for_votes + value else proposal.against_votes = proposal.against_votes + value;

    let proposal_id = object::id(proposal);

    emit(CastVote<DAOWitness, ModuleWitness,  CoinType, T>{ proposal_id: proposal_id, value, voter: tx_context::sender(ctx), end_time: proposal.end_time, agree });

    Vote {
      id: object::new(ctx),
      agree,
      balance: coin::into_balance(stake),
      end_time: proposal.end_time,
      proposal_id: proposal_id
    }
  }

  public fun change_vote<DAOWitness: drop, ModuleWitness: drop, CoinType, T: store>(
    proposal: &mut Proposal<DAOWitness, ModuleWitness,  CoinType, T>,
    vote: &mut Vote<DAOWitness, ModuleWitness,  CoinType, T>,
    c: &Clock,
    ctx: &mut TxContext
  ) {
    assert!(get_proposal_state(proposal, clock::timestamp_ms(c)) == ACTIVE, EProposalMustBeActive);
    let proposal_id = object::id(proposal);
    assert!(proposal_id == vote.proposal_id, EVoteAndProposalIdMismatch);
    let value = balance::value(&vote.balance);

    vote.agree = !vote.agree;

    if (vote.agree) {
      proposal.against_votes = proposal.against_votes - value;
      proposal.for_votes = proposal.for_votes + value;
    } else {
      proposal.for_votes = proposal.for_votes - value;
      proposal.against_votes = proposal.against_votes + value;
    };

    emit(ChangeVote<DAOWitness, ModuleWitness,  CoinType, T>{ proposal_id, value, voter: tx_context::sender(ctx), end_time: proposal.end_time, agree: vote.agree, vote_id: object::id(vote) });
  }

  public fun revoke_vote<DAOWitness: drop, ModuleWitness: drop, CoinType, T: store>(
    proposal: &mut Proposal<DAOWitness, ModuleWitness,  CoinType, T>,
    vote: Vote<DAOWitness, ModuleWitness,  CoinType, T>,
    c: &Clock,
    ctx: &mut TxContext    
  ): Coin<CoinType> {
    assert!(get_proposal_state(proposal, clock::timestamp_ms(c)) == ACTIVE, EProposalMustBeActive);
    let proposal_id = object::id(proposal);
    assert!(proposal_id == vote.proposal_id, EVoteAndProposalIdMismatch);

    let value = balance::value(&vote.balance);
    if (vote.agree) proposal.for_votes = proposal.for_votes - value else proposal.against_votes = proposal.against_votes - value;

    emit(RevokeVote<DAOWitness, ModuleWitness,  CoinType, T>{ proposal_id: proposal_id, value, agree: vote.agree, voter: tx_context::sender(ctx) });

    destroy_vote(vote, ctx)
  }

  public fun unstake_vote<DAOWitness: drop, ModuleWitness: drop, CoinType, T: store>(
    proposal: &Proposal<DAOWitness, ModuleWitness,  CoinType, T>,
    vote: Vote<DAOWitness, ModuleWitness,  CoinType, T>,
    c: &Clock,
    ctx: &mut TxContext      
  ): Coin<CoinType> {
    // Everything greater than active can be unstaked 
    assert!(get_proposal_state(proposal, clock::timestamp_ms(c)) > ACTIVE, ECannotUnstakeFromAnActiveProposal);
    let proposal_id = object::id(proposal);
    assert!(proposal_id == vote.proposal_id, EVoteAndProposalIdMismatch);

    emit(UnstakeVote<DAOWitness, ModuleWitness,  CoinType, T>{ proposal_id: proposal_id, value: balance::value(&vote.balance), agree: vote.agree, voter: tx_context::sender(ctx) });

    destroy_vote(vote, ctx)
  }

  public fun execute_proposal<DAOWitness: drop, ModuleWitness: drop, CoinType, T: store>(
    proposal: &mut Proposal<DAOWitness, ModuleWitness,  CoinType, T>, 
    c: &Clock
  ): Action<DAOWitness, ModuleWitness, CoinType, T> {
    let now = clock::timestamp_ms(c);
    assert!(get_proposal_state(proposal, now) == EXECUTABLE, ECannotExecuteThisProposal);
    assert!(now >= proposal.end_time + proposal.action_delay, ETooEarlyToExecute);

    let payload = option::extract(&mut proposal.payload);

    Action {
      payload
    }
  }

  public fun finish_action<DAOWitness: drop, ModuleWitness: drop, CoinType, T: store>(_: ModuleWitness, action: Action<DAOWitness, ModuleWitness, CoinType, T>): T {
    let Action { payload } = action;
    payload
  }

  public fun proposal_state<DAOWitness: drop, ModuleWitness: drop, CoinType, T: store>(proposal: &Proposal<DAOWitness, ModuleWitness,  CoinType, T>, c: &Clock): u8 {
    get_proposal_state(proposal, clock::timestamp_ms(c))
  }

  public fun view_vote<DAOWitness: drop, ModuleWitness: drop, CoinType, T: store>(
    vote: &Vote<DAOWitness, ModuleWitness,  CoinType, T>
  ): (ID, ID, u64, bool, u64) {
    (object::id(vote), vote.proposal_id, balance::value(&vote.balance), vote.agree, vote.end_time)
  }

  public fun view_proposal<DAOWitness: drop, ModuleWitness: drop, CoinType, T: store>(
    proposal: &Proposal<DAOWitness, ModuleWitness,  CoinType, T>, 
    c: &Clock
  ): (ID, address, u8, u64, u64, u64, u64, u64, u64, u64, &Option<T>) {
    (object::id(proposal), proposal.proposer, proposal_state(proposal, c), proposal.start_time, proposal.end_time, proposal.for_votes, proposal.against_votes, proposal.eta, proposal.action_delay, proposal.quorum_votes, &proposal.payload)
  }

  fun propose<DAOWitness: drop, ModuleWitness: drop, CoinType, T: store>(
    dao: &mut DAO<DAOWitness, CoinType>,
    c: &Clock,
    payload: Option<T>,
    action_delay: u64,
    quorum_votes: u64,
    ctx: &mut TxContext    
  ): Proposal<DAOWitness, ModuleWitness,  CoinType, T> {
    assert!(action_delay >= dao.min_action_delay, EActionDelayTooSmall);
    assert!(quorum_votes >= dao.min_quorum_votes, EMinQuorumVotesTooSmall);

    let start_time = clock::timestamp_ms(c) + dao.voting_delay;

    let proposal = Proposal {
      id: object::new(ctx),
      proposer: tx_context::sender(ctx),
      start_time,
      end_time: start_time + dao.voting_period,
      for_votes: 0,
      against_votes: 0,
      eta: 0,
      action_delay,
      quorum_votes,
      voting_quorum_rate: dao.voting_quorum_rate,
      payload
    };
    
    emit(NewProposal<DAOWitness, ModuleWitness,  CoinType, T> { proposal_id: object::id(&proposal), proposer: proposal.proposer });

    proposal
  }

  fun destroy_vote<DAOWitness: drop, ModuleWitness: drop, CoinType, T: store>(vote: Vote<DAOWitness, ModuleWitness,  CoinType, T>, ctx: &mut TxContext): Coin<CoinType> {
    let Vote {id, balance, agree: _, end_time: _, proposal_id: _} = vote;
    object::delete(id);

    coin::from_balance(balance, ctx)
  }

  fun get_proposal_state<DAOWitness: drop, ModuleWitness: drop, CoinType, T: store>(
    proposal: &Proposal<DAOWitness, ModuleWitness,  CoinType, T>,
    current_time: u64,
  ): u8 {
    if (current_time < proposal.start_time) {
      // Pending
      PENDING
    } else if (current_time <= proposal.end_time) {
      // Active
      ACTIVE
    } else if (proposal.for_votes <= proposal.against_votes ||
      proposal.for_votes < proposal.quorum_votes || proposal.voting_quorum_rate > wad_div_down((proposal.for_votes as u128), ((proposal.for_votes + proposal.against_votes) as u128)) ) {
      // Defeated
      DEFEATED
    } else if (proposal.eta == 0) {
      // Agreed.
      AGREED
    } else if (current_time < proposal.eta) {
      // Queued, waiting to execute
      QUEUED
    } else if (option::is_some(&proposal.payload)) {
      EXECUTABLE
    } else {
      EXTRACTED
    }
    }

  
   // Only Proposal can update DAO settings

   public fun make_dao_config(
    voting_delay: u64,
    voting_period: u64,
    voting_quorum_rate: u128,
    min_action_delay: u64,
    min_quorum_votes: u64,
    ctx: &mut TxContext  
   ): DaoConfig {
    DaoConfig {
      id: object::new(ctx),
      voting_delay: if (voting_delay == 0)  option::none() else option::some(voting_delay),
      voting_period: if (voting_period == 0) option::none() else option::some(voting_period),
      voting_quorum_rate:  if (voting_quorum_rate == 0) option::none() else option::some(voting_quorum_rate),
      min_action_delay: if (min_action_delay == 0) option::none() else option::some(min_action_delay),
      min_quorum_votes: if (min_quorum_votes == 0) option::none() else option::some(min_quorum_votes),
    }
   } 

   public fun update_dao_config<DAOWitness: drop, ModuleWitness: drop, CoinType>(
    dao: &mut DAO<DAOWitness, CoinType>,
    action: Action<DAOWitness, ModuleWitness, CoinType, DaoConfig>
   ) {

    let Action { payload } = action;

    let DaoConfig { id, voting_delay, voting_period, voting_quorum_rate, min_action_delay, min_quorum_votes  } = payload;

    object::delete(id);

    if (option::is_some(&voting_delay)) dao.voting_delay = option::destroy_with_default(voting_delay, dao.voting_delay);
    if (option::is_some(&voting_period)) dao.voting_period = option::destroy_with_default(voting_period, dao.voting_period);
    if (option::is_some(&voting_quorum_rate)) dao.voting_quorum_rate = option::destroy_with_default(voting_quorum_rate, dao.voting_quorum_rate);
    if (option::is_some(&min_action_delay)) dao.min_action_delay = option::destroy_with_default(min_action_delay, dao.min_action_delay);
    if (option::is_some(&min_quorum_votes)) dao.min_quorum_votes = option::destroy_with_default(min_quorum_votes, dao.min_quorum_votes);

    assert!(100 * wad() >= dao.voting_quorum_rate && dao.voting_quorum_rate != 0, EInvalidQuorumRate);
    assert!(dao.voting_delay != 0, EInvalidVotingDelay);
    assert!(dao.voting_period != 0, EInvalidVotingPeriod);
    assert!(dao.min_action_delay != 0, EInvalidMinActionDelay);
    assert!(dao.min_quorum_votes != 0, EInvalidMinQuorumVotes);

    emit(
      UpdateDAO<DAOWitness, CoinType> {
        dao_id: object::id(dao),
        voting_delay: dao.voting_delay,
        voting_period: dao.voting_period,
        voting_quorum_rate: dao.voting_quorum_rate,
        min_action_delay: dao.min_action_delay,
        min_quorum_votes: dao.min_quorum_votes
      }
    );
   }
}
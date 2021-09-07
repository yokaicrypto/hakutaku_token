pragma solidity ^0.8.3;

/*
 * \title Hakutaku token
 * \brief Token that every X hours rewards a randomly selected holder (that held for long enough)
 *  			with the total amount accumulated in a pool from transaction fees
 * \version 1.0b experimental
 * \author unknown
 */

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

contract HTT is ERC20, Ownable {

	address prize_pool;				//!< prize draw pool address

	uint prize_pool_fee;			//!< percent fee on every transaction that goes towards prize pool (1-10% limit)
	uint prize_frequency;			//!< how often does the prize draw happen (1h - 1d limit)
	uint hold_balance_limit;	//!< amount to hold to be eligible for a prize draw (1-1M token limit)
	uint hold_time_limit;			//!< must hold at least this time (2-25 hr limit)
			
	struct Holder {
		address addr;
		uint time; 	// timestamp when accumulated enough HTT
	}
	Holder[] holders;		//!< holders (will become diamond hands once time passes)
	
	struct Diamond {
		address addr;
		uint value; // value with which became a diamond hands holder
	}
	Diamond[] diamonds;	//!< eligible holders for the reward (diamond hands)
	
	mapping(address => uint) holder_indexes;	//!< mapping of address to indexes in holders array
	mapping(address => uint) diamond_indexes;	//!< mapping of address to indexes in diamonds array
	uint prize_last_time;											//!< last time the prize draw happened
	uint prize_last_amount;										//!< last amount given to rewardee
	uint totalam;															//!< total amount of tokens diamond hands accumulated
	
	bool buy_limit; //!< protection from whales (removed shortly after the launch)

  constructor(
			address _prize_pool, 
			uint _prize_pool_fee,
			uint _prize_frequency,
			uint _hold_balance_limit,
			uint _hold_time_limit,
			bool _buy_limit) 
			Ownable() ERC20('Hakutaku Token', 'HAKU') {
			
    _mint(msg.sender, 1000000000 * 10 ** 18);
		_addHolder(msg.sender); // fill index 0
		_addDiamond(msg.sender, _hold_balance_limit); // fill index 0
		totalam = 0; // init totalam
		
		prize_pool = _prize_pool; // hardcoded prize pool (this account will not be able to trade tokens!)
		
		setPrizePoolFee(_prize_pool_fee);
		setHoldTimeLimit(_hold_time_limit);
		setPrizeFrequency(_prize_frequency);
		setHoldBalanceLimit(_hold_balance_limit);

		prize_last_time = block.timestamp; // init prize timestamp
		prize_last_amount = 0;
		
		buy_limit = _buy_limit;
  }
  
  /*! 
   * \title Override transfer function
   * \brief Takes prize fee from every transaction
	 *        Initiates reward prize draw
   */
  function _transfer(address from, address to, uint256 value) override internal {
		// block prize pool from dumping tokens
		require(from != prize_pool, "prize pool cannot trade tokens");
		require(to != prize_pool, "prize pool cannot trade tokens");
		
		// put fee into the prize pool
		if(from != owner() && to != owner()) {
			uint256 prize_fee = calcFee(value);
			value -= prize_fee; // take fee out
			if(buy_limit) {
				require(value <= hold_balance_limit, "buy/sell limit");
				require(balanceOf(to) + value <= hold_balance_limit, "hold limit");
			}
			super._transfer(from, prize_pool, prize_fee);
		}
		super._transfer(from, to, value);
		
		// are there pending holders waiting to become diamond hands?
		if(holders.length > 1) {
			uint i = holders.length-1;
			uint steps = 0;
			// process max 10 at a time to save gas
			while(steps < 10 && i > 0) {
				if(holder_indexes[holders[i].addr] > 0 && diamond_indexes[holders[i].addr] == 0 && holders[i].time > 0 && (block.timestamp - holders[i].time) >= hold_time_limit) { 
					_addDiamond(holders[i].addr, balanceOf(holders[i].addr)); // add to diamond hands
					_removeHolder(holders[i].addr); // delete from pending
				}
				steps++;
				i--;
			}	
		}
		
		// do we need to trigger a reward?
		if(block.timestamp > prize_last_time && (block.timestamp - prize_last_time) >= prize_frequency && balanceOf(prize_pool) > 0) {
			prize_last_time = block.timestamp; // update last time a prize was given
			// prize given only if there are diamond hands
			if(diamonds.length > 1) {
				// calc total amount for mid, 1/4 and 3/4 holder
				uint indmid = uint(diamonds.length) / uint(2);
				uint indlq = indmid / uint(2);
				uint totalamex = diamonds[indmid].value + diamonds[indlq].value + diamonds[indlq+indmid].value;
					
				// choose a rewardee from diamond hands holders
				uint rewardee_ind = 1 + getHakutakuChoice(diamonds.length-1, totalamex); // if we get 0, it's 1
				prize_last_amount = balanceOf(prize_pool);
				// give everything from the prize pool to the rewardee
				super._transfer(prize_pool, diamonds[rewardee_ind].addr, prize_last_amount);
			}
		}
		
		// if accumulated enough and not in holders yet -- add
		// note1: owner is a permanent holder (but will never take part in prize draws!)
		// note2: prize_pool is not in holders and never will be
		// note3: owner and prize pool do not get added or removed to these lists after constructor
		uint bto = balanceOf(to);
		uint bfrom = balanceOf(from);
		if(bto >= hold_balance_limit && holder_indexes[to] == 0 && diamond_indexes[to] == 0 && to != owner() && to != prize_pool) {
			_addHolder(to);
		}
		if(bfrom >= hold_balance_limit && holder_indexes[from] == 0 && diamond_indexes[from] == 0 && from != owner() && from != prize_pool) {
			_addHolder(from);
		}
		// if below hold limit (he sold? d0mp him!)
		if(bfrom < hold_balance_limit && from != owner() && from != prize_pool) {
			if(holder_indexes[from] > 0) {
				_removeHolder(from);				
			}
			if(diamond_indexes[from] > 0) {
				_removeDiamond(from);
			}
		}
		if(bto < hold_balance_limit && to != owner() && to != prize_pool) {
			if(holder_indexes[to] > 0) {
				_removeHolder(to);				
			}
			if(diamond_indexes[to] > 0) {
				_removeDiamond(to);
			}
		}
	}
	
	/*!
	 * \title Hakutaku makes a choice of the rewardee
	 * \brief He decides based on what holders did. It is completely decentralised.
	 * Warning: the choice is pseudo-random, not strictly random, this code is experimental
	 * Note, however, that the hypothetical effort to turn this choice into personal benefit via an exploit
	 * is expected to be larger than the benefit because of the holding time limit, holding amount limit and 
	 * randomness introduced by holder actions. Moreover, the frequency of the prize draw in comparison with 
	 * the holding time limit and holding balance limit makes the cost of manipulation too high. 
	 * With that being said, we don't make any claims, it is experimental, always do your own research.
	 * \return index of the rewardee
	 */
	function getHakutakuChoice(uint num, uint totalamex) internal view returns(uint) {
		return uint(keccak256(abi.encodePacked(totalam, totalamex, prize_last_amount))) % num;
	}
		
  /*! 
   * \title Calculate prize fee for a transaction value
   * \return fee in tokens
   */
	function calcFee(uint256 value) public view returns (uint256) {
		return (value / 100) * prize_pool_fee;
	}
			
	function _addHolder(address holder) internal {
		holders.push(Holder(holder, block.timestamp));
		holder_indexes[holder] = holders.length - 1;
	}
	
	function _removeHolder(address holder) internal {
		uint ind = holder_indexes[holder];
		if(ind < holders.length-1) {
			holders[ind] = holders[holders.length-1]; 	// replace current index with last holder
			holder_indexes[holders[ind].addr] = ind; 		// update last holder's index to new one			
		} 
		holders.pop(); // pop last item of the holders
		delete holder_indexes[holder]; // clear the holder who sold
	}

	function _addDiamond(address diamond, uint value) internal {
		diamonds.push(Diamond(diamond, value));
		diamond_indexes[diamond] = diamonds.length - 1;
		totalam += value;
	}
	
	function _removeDiamond(address diamond) internal {
		uint ind = diamond_indexes[diamond];
		totalam -= diamonds[ind].value; 								// his value is out of the totalam
		if(ind < diamonds.length-1) {
			diamonds[ind] = diamonds[diamonds.length-1]; 	// replace current index with last diamond
			diamond_indexes[diamonds[ind].addr] = ind; 		// update last diamond's index to new one			
		} 
		diamonds.pop(); // pop last item of the holders
		delete diamond_indexes[diamond]; // clear the diamond who sold
	}
		
	function getPrizeLastTime() external view returns (uint) {
		return prize_last_time;
	}
	
	function getPrizePoolFee() external view returns (uint) {
		return prize_pool_fee;
	}

	function getPrizeFrequency() external view returns (uint) {
		return prize_frequency;
	}

	function getHoldBalanceLimit() external view returns (uint) {
		return hold_balance_limit;
	}

	function getHoldTimeLimit() external view returns (uint) {
		return hold_time_limit;
	}
	
	function getHoldersCount() external view returns(uint)	{
		return holders.length;
	}
	
	function getDiamondsCount() external view returns(uint) {
		return diamonds.length;
	}
		
	function setPrizeFrequency(uint _prize_frequency) public onlyOwner {
		require(_prize_frequency >= 1800 && _prize_frequency <= 86400, "frequency of the reward must be between 30m and 1d");
		require(hold_time_limit >= 3600 + _prize_frequency, "houd hour limit must be at least 1 hour longer than reward frequency");
		prize_frequency = _prize_frequency;
	}

	function setPrizePoolFee(uint _prize_pool_fee) public onlyOwner {
		require(_prize_pool_fee >= 1 && _prize_pool_fee <= 10, "prize pool fee must be 1-10%");
		prize_pool_fee = _prize_pool_fee;
	}

	function setHoldBalanceLimit(uint _hold_balance_limit) public onlyOwner {
		require(_hold_balance_limit >= 1 * 10 ** 18 && _hold_balance_limit <= 10000000 * 10 ** 18, "balance limit must be between 1 and 10M");
		hold_balance_limit = _hold_balance_limit;
	}

	function setHoldTimeLimit(uint _hold_time_limit) public onlyOwner {
		require(_hold_time_limit >= 7200 && _hold_time_limit <= 90000, "hold time limit has to be between 2 and 25");
		require(_hold_time_limit >= 3600 + prize_frequency, "hold time limit must be at least 1 hour longer than reward frequency");
		hold_time_limit = _hold_time_limit;
	}
		
	function removeBuyLimit() external onlyOwner {
		buy_limit = false; // can be done only once and can't be reverted!
	}
}
// CFD contract example by Gav Wood.
// Copyright 2015, 2016 Ethcore (UK) Ltd.

// Parity is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// Parity is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with Parity.  If not, see <http://www.gnu.org/licenses/>.

/*
Each contract instance has a fixed period (1 week here, but trivial to
change) and a fixed oracle (set on init).

Each deal has two parties; both put in a stake of ETH, one (the "stable"
party) exits with the new ETH valuation of the same underlying
asset-equivalent at time of entry. The other (the "leveraged" party) with
whatever is left.

A deal may be finalized (and the value of either party determined and 
transferred) only once the deal period is up or the asset value has more
then doubled (prompting an early-exit option from the contract to prevent
the "stable" party from losing due to an under-collateralised counter-patry.

Valuation of the foreign asset comes from an Oracle contract.

An orderbook is maintained for both sides. Orders may specify an arbitrary
stake.

Orders may require a price adjustment (specified in billionths) applied
to the valuation of the foreign asset at the start of the deal. For stable
orders, the adjustment is assumed to be a lower limit (an eventual deal may
have a higher actual adjustment); likewise for leveraged orders is is assumed
to specify an upper bound.

A simple matching algorithm creates deals from alterations in the orderbook.
In the case of a range of allowable adjustments from the matched orders, the
minimum acceptable adjustment (i.e. that giving a final price closest to the
actual price) is used.

Basic idea for finalization stable / leveraged; stake is 100 @ $10 ($1000
effective stake in either side):
           $   / ETH!
  - $1000: 1   / 199
  - $20:   50  / 150
  - $10:   100 / 100
  - $6.66: 150 / 50
  - $5:    200 / 0


Adjustment is the adjustment to the /original/ price in billionths, assuming
stake is 100 @ $10:

  adjustment   meaning if end price = $10
               $   / ETH! / start price
  1.0 x10^9    100 / 100  / $10
  1.5 x10^9    150 / 50   / $15
  0.5 x10^9    50  / 150  / $5

Thus higher adjustments favour stable party, lower adjustments favour
leveraged.
*/

contract owned {
    function owned() {
        owner = msg.sender;
    }
    
    function set_owner(address _new) only_owner {
        owner = _new;
    }
    
    modifier only_owner { if (msg.sender == owner) _ }
    
    address public owner;
}

contract Oracle is owned {
    function Oracle() {}
	
	event Changed(uint224 current);
    
    struct Value {
        uint32 timestamp;
        uint224 value;
    }
    
    function note(uint224 _value) only_owner {
		if (data.value != _value) {
			data.value = _value;
			Changed(_value);
		}
		data.timestamp = uint32(now);
    }
    
    function get() constant returns (uint224) {
        return data.value;
    }

    function get_timestamp() constant returns (uint32) {
        return data.timestamp;
    }

    Value public data;
}

contract CFD {
	struct Order {
		address who;
		bool is_stable;
		uint32 adjustment;	// billionths by which to adjust start-price
		uint128 stake;

		uint32 prev_id;		// a linked ring
		uint32 next_id;		// a linked ring
	}

	struct Deal {
		address stable;		// fixed to the alternative asset, and tracking the price feed of oracle
		address leveraged;	// aka volatile (what's left from stable)
		uint64 strike;
		uint128 stake;
		uint32 end_time;

		uint32 prev_id;		// a linked ring
		uint32 next_id;		// a linked ring
	}

	event Deposit(address indexed who, uint value);
	event Withdraw(address indexed who, uint value);
	event OrderPlaced(uint32 indexed id, address indexed who, bool indexed is_stable, uint32 adjustment, uint128 stake);
	event OrderMatched(uint32 indexed id, address indexed stable, address indexed leveraged, bool is_stable, uint32 deal, uint64 strike, uint128 stake);
	event OrderCancelled(uint32 indexed id, address indexed who, uint128 stake);
	event DealFinalized(uint32 indexed id, address indexed stable, address indexed leveraged, uint64 price);

	function CFD(address _oracle) {
		oracle = Oracle(_oracle);
		period = 10 minutes;
	}
	
	function best_adjustment(bool _is_stable) constant returns (uint32) {
		_is_stable = !!_is_stable;
		var head = _is_stable ? stable : leveraged;
		return head == 0 ? 0 : orders[head].adjustment;
	}

	function best_adjustment_for(bool _is_stable, uint128 _stake) constant returns (uint32) {
		_is_stable = !!_is_stable;
		var head = _is_stable ? stable : leveraged;
		if (head == 0)
			return 0;
		var i = head;
		uint128 accrued = 0;
		for (; orders[i].next_id != head && accrued + orders[i].stake < _stake; i = orders[i].next_id)
			accrued += orders[i].stake;
		return accrued + orders[i].stake >= _stake ? orders[i].adjustment : 0;
	}
	
	function deal_details(uint32 _id) constant returns (address stable, address leveraged, uint64 strike, uint128 stake, uint32 end_time) {
		stable = deals[_id].stable;
		leveraged = deals[_id].leveraged;
		strike = deals[_id].strike;
		stake = deals[_id].stake;
		end_time = deals[_id].end_time;
	}
	
	function balance_of(address _who) constant returns (uint) {
		return accounts[_who];
	}
	
	// deposit funds.
	function() {
		accounts[msg.sender] += msg.value;
		Deposit(msg.sender, msg.value);
	}
	
	/// withdraw funds.
	function withdraw(uint value) {
		if (value > accounts[msg.sender])
			value = accounts[msg.sender];
		msg.sender.send(value);
		accounts[msg.sender] -= value;
		Withdraw(msg.sender, value);
	}

	function order(bool is_stable, uint32 adjustment, uint128 stake) {
		if (msg.value == 0) {
			if (stake > accounts[msg.sender])
				return;
			accounts[msg.sender] -= stake;
		} else 
			stake = uint128(msg.value);
		
		if (stake < min_stake)
			return;

		// sanitize is_stable due to broken web3.js passing it as 'true'
		is_stable = !!is_stable;
		
		// while there's an acceptable opposing order
		while (stake > 0) {
			var head = is_stable ? leveraged : stable;
			if (head == 0)
				break;
			var hadj = orders[head].adjustment;
			if (hadj != adjustment && (hadj < adjustment) == is_stable)
				break;

			// order matches; make a deal.
			var this_stake = orders[head].stake < stake ? orders[head].stake : stake;
			var strike = find_strike(uint64(oracle.get()), is_stable ? adjustment : hadj, is_stable ? hadj : adjustment);
			insert_deal(is_stable ? msg.sender : orders[head].who, is_stable ? orders[head].who : msg.sender, strike, this_stake, head);

			stake -= this_stake;
			if (this_stake == orders[head].stake)
				remove_order(head);
		}

		// if still unfulfilled place what's left in orderbook
		if (stake > 0)
			insert_order(msg.sender, is_stable == true, adjustment, stake);
	}

	/// withdraw an unfulfilled order, or part thereof.
	function cancel(uint32 id) {
		if (orders[id].who == msg.sender) {
			accounts[msg.sender] += orders[id].stake;
			OrderCancelled(id, msg.sender, orders[id].stake);
			remove_order(id);
		}
	}

	/// lock the current price into a now-ended or out-of-bounds deal.
	function finalize(uint24 id) {
		var price = uint64(oracle.get());
		var strike = deals[id].strike;

		// can't handle the price dropping by over 50%.
		var early_exit = price < strike / 2;
		if (early_exit)
			price = strike / 2;

		if (now >= deals[id].end_time || early_exit) {
			var stake = deals[id].stake;
			var stable_gets = stake * strike / price;
			accounts[deals[id].stable] += stable_gets;
			accounts[deals[id].leveraged] += stake * 2 - stable_gets;
			DealFinalized(id, deals[id].stable, deals[id].leveraged, price);
			remove_deal(id);
		}
	}

	// inserts the order into one of the two lists, ordered according to adjustment.
	function insert_order(address who, bool is_stable, uint32 adjustment, uint128 stake) internal returns (uint32 id) {
		id = next_id;
		++next_id;

		orders[id].who = who;
		orders[id].is_stable = is_stable;
		orders[id].adjustment = adjustment;
		orders[id].stake = stake;

		var head = is_stable ? stable : leveraged;

		var adjust_head = true;
		if (head != 0) {
			// find place to insert
			var i = head;
			for (; (i != head || adjust_head) && (orders[i].adjustment == adjustment || ((orders[i].adjustment < adjustment) == is_stable)); i = orders[i].next_id)
				adjust_head = false;

			// we insert directly before i, and point head to there iff adjust_head.
			orders[id].prev_id = orders[i].prev_id;
			orders[id].next_id = i;
			orders[orders[i].prev_id].next_id = id;
			orders[i].prev_id = id;
		} else {
			// nothing in queue yet, so just place the head
			orders[id].next_id = id;
			orders[id].prev_id = id;
		}
		if (adjust_head) {
			if (is_stable)
				stable = id;
			else
				leveraged = id;
		}

		OrderPlaced(id, who, is_stable, adjustment, stake);
	}

	// removes an order from one of the two lists
	function remove_order(uint32 id) internal {
		// knit out
		if (orders[id].prev_id != id) {
			// if there's at least another deal in the list, reknit.
			if (stable == id)
				stable = orders[id].next_id;
			else if (leveraged == id)
				leveraged = orders[id].next_id;
			orders[orders[id].prev_id].next_id = orders[id].next_id;
			orders[orders[id].next_id].prev_id = orders[id].prev_id;
		}
		else 
			if (stable == id)
				stable = 0;
			else if (leveraged == id)
				leveraged = 0;

		delete orders[id];
	}

	// inserts the deal into deals at the end of the list.
	function insert_deal(address stable, address leveraged, uint64 strike, uint128 stake, uint32 order) internal returns (uint32 id) {
		// knit in at the end
		id = next_id;
		++next_id;

		deals[id].stable = stable;
		deals[id].leveraged = leveraged;
		deals[id].strike = strike;
		deals[id].stake = stake;
		deals[id].end_time = uint32(now) + period;

		if (head != 0) {
			deals[id].prev_id = deals[head].prev_id;
			deals[id].next_id = head;
			deals[deals[head].prev_id].next_id = id;
			deals[head].prev_id = id;
		} else {
			deals[id].prev_id = id;
			deals[id].next_id = id;
		}

		OrderMatched(order, stable, leveraged, msg.sender == stable, id, strike, stake);
	}

	// removes the deal id from deals.
	function remove_deal(uint32 id) internal {
		// knit out
		if (deals[id].prev_id != id) {
			// if there's at least another deal in the list, reknit.
			if (head == id)
				head = deals[id].next_id;
			deals[deals[id].prev_id].next_id = deals[id].next_id;
			deals[deals[id].next_id].prev_id = deals[id].prev_id;
		}
		else 
			if (head == id)
				head = 0;
		delete deals[id];
	}

	// return price * the stake v which is closest to 1000000000 fullfilling (v >= min(stable, leveraged), v <= max(stable, leveraged)) / 1000000000
	function find_strike(uint64 price, uint32 stable, uint32 leveraged) internal returns (uint64) {
		var stable_is_pos = stable > 1000000000;
		var leveraged_is_pos = leveraged > 1000000000;
		if (stable_is_pos != leveraged_is_pos)
			return price;
		else
			return price * ((stable_is_pos == (leveraged < stable)) ? leveraged : stable) / 1000000000;
	}

	Oracle public oracle;
	uint32 public period;
	
	uint32 public next_id = 1;

	mapping (uint32 => Order) public orders;
	uint32 public leveraged;		// insert into linked ring, ordered ASCENDING by adjustment.
	uint32 public stable;			// insert into linked ring, ordered DESCENDING by adjustment.

	mapping (uint32 => Deal) public deals;
	uint32 public head;			// insert into linked ring; no order.
	
	uint128 min_stake = 100 finney;	// minimum stake to avoid dust clogging things up.

	mapping (address => uint) public accounts;
}
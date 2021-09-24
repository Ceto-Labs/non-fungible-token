import Array "mo:base/Array";
import HashMap "mo:base/HashMap";
import NftTypes "types";
import Text "mo:base/Text";
import Debug "mo:base/Debug";


module {
    let max_limit = 1000000;

    public func add(
        map : HashMap.HashMap<Principal, HashMap.HashMap<Text, Nat>>,
        owner : Principal,
        token : NftTypes.Token,
    ) : Bool {
        switch(map.get(owner)) {
            // Add key iof it does not exist.
            case null {
                var newV = HashMap.HashMap<Text, Nat>(1, Text.equal, Text.hash);
                newV.put(token.id, token.amount);
                map.put(owner, newV);
            };
            // Key already exists.
            case (? subMap) {
                // Checks whether the array reached/exceeded the limit.
                if (subMap.size() >= max_limit) {
                    return false;
                };

                switch(subMap.get(token.id)){
                    case (? oldAmount){
                        subMap.put(token.id, oldAmount + token.amount);
                    };
                    case(_){
                        subMap.put(token.id, token.amount);
                    };
                };

                map.put(owner, subMap);
            };
        };
        return true;
    };

    public func sub(
        map : HashMap.HashMap<Principal, HashMap.HashMap<Text, Nat>>,
        owner : Principal,
        token : NftTypes.Token,
    ) : Bool {
        switch(map.get(owner)) {
            // Key does not exist.
            case null {assert(false)};
            // Key exists.
            case (? subMap) {
                switch(subMap.get(token.id)){
                    case (? oldAmount){
                        assert(oldAmount >= token.amount);
                        if (oldAmount == token.amount){
                            subMap.delete(token.id);
                            return true;
                        } else {subMap.put(token.id, oldAmount - token.amount);};
                        map.put(owner, subMap);
                    };
                    case (_){assert(false)};
                };
            };
        };
        return false;
    };

    public func burn(
        map : HashMap.HashMap<Principal, HashMap.HashMap<Text, Nat>>,
        caller : Principal,
        id : Text,
        amount : Nat,
    ) : Bool {
        switch(map.get(caller)){
            case (null) {
                assert(false);
            };
            case (?subMap){
                switch (subMap.get(id)){
                    case (null){ assert(false)};
                    case (?oldAmount){                                        
                        if (oldAmount > amount){
                            subMap.put(id, oldAmount - amount);
                            map.put(caller, subMap);
                        } else if (oldAmount == amount) {
                            subMap.delete(id);
                            if (subMap.size() == 0){
                                map.delete(caller);
                            } else { map.put(caller, subMap);};
                            return true;                            
                        } else { assert(false);};
                    };
                };
            };
        };
        return false;
    };

    public func balanceOf(map : HashMap.HashMap<Principal, HashMap.HashMap<Text, Nat>>,
        owner : Principal, 
        id : Text
    ) : Nat {
        switch (map.get(owner)) {
            case (?subMap){
                switch(subMap.get(id)){
                    case (null){0};
                    case (?v){v};
                }; 
            };
            case (null) {0};
        };
    };
};

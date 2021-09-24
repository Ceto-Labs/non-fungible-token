import Array "mo:base/Array";
import HashMap "mo:base/HashMap";
import NftTypes "types";
import Text "mo:base/Text";
import Debug "mo:base/Debug";
import Principal "mo:base/Principal";

module {

    public func updateAuthorized(authorized : HashMap.HashMap<Principal,  HashMap.HashMap<Principal, [NftTypes.Token]>>,
        caller : Principal,
        r : NftTypes.AuthorizeRequest,
    )  {
        let token : NftTypes.Token = {
           amount = r.amount;
           id = r.id;
        };
        switch(r.amount != 0) {
            case (true) {
                switch(authorized.get(caller)){
                    case (?subMap){
                        switch(subMap.get(r.user)){
                            case null {
                                subMap.put(r.user, [token]);
                            };
                            case (?tokens){
                                var newTokens = Array.filter<NftTypes.Token>(tokens, func(v){v.id != r.id});
                                newTokens := Array.append<NftTypes.Token>(newTokens, [token]);
                                subMap.put(r.user, newTokens);
                            };
                        };
                        authorized.put(caller, subMap);
                    };
                    case (null){
                        let subMap = HashMap.HashMap<Principal,[NftTypes.Token]>(1, Principal.equal, Principal.hash);
                        subMap.put(r.user, [token]);
                        authorized.put(caller, subMap);
                    };
                };
            };
            case (false) {
                switch(authorized.get(caller)){
                    case (?subMap){
                        switch(subMap.get(r.user)){
                            case null {};
                            case (? tokens){
                                var newTokens = Array.filter<NftTypes.Token>(tokens, func(v){v.id != r.id});
                                if (newTokens.size() > 0){
                                    subMap.put(r.user, newTokens);
                                    authorized.put(caller, subMap);
                                } else {
                                    subMap.delete(r.user);
                                    if (subMap.size() == 0){
                                        authorized.delete(caller);
                                    } else {
                                        authorized.put(caller, subMap);
                                    }
                                };
                            };
                        };
                    };
                    case (null){};
                };
            };
        };
    };

    public func removeAuthorized(authorized : HashMap.HashMap<Principal,  HashMap.HashMap<Principal, [NftTypes.Token]>>,
        caller : Principal,
        from : Principal,
        id : Text
    ) : Bool {
        switch(authorized.get(from)){
            case null {Debug.print("r0");return false};
            case (?subMap){
                switch(subMap.get(caller)){
                    case null {Debug.print(debug_show("r1","caller:",caller, from));return false};
                    case (?tokens){
                        let leftTokens = Array.filter<NftTypes.Token>(tokens, func(v){v.id != id});
                        if (leftTokens.size() == 0){
                            subMap.delete(caller);
                        } else {
                            subMap.put(caller, leftTokens);
                        };
                        authorized.put(from, subMap);
                        return true;
                    };
                };
            };
        };
    };

    public func isAuthorized(authorized : HashMap.HashMap<Principal,  HashMap.HashMap<Principal, [NftTypes.Token]>>,
        caller : Principal,
        from : Principal, 
        id : Text,
        amount : Nat
    ) : Bool {
        switch(authorized.get(from)) {
            case null {Debug.print("i 0");return false}; 
            case (?subMap) {
                switch(subMap.get(caller)){
                    case null {
                        Debug.print(debug_show("i 1", "caller",caller, "from",from, subMap.size()));
                        for ((k,v) in subMap.entries()){
                            Debug.print(debug_show("submap:",k,v));
                        };
                        return false
                    };
                    case (?tokens){
                        switch(Array.find<NftTypes.Token>(tokens, func(v){v.id == id})){
                            case null {Debug.print("i 2");return false};
                            case (?v) {
                                 return v.amount >= amount;
                            };
                        };                                
                    };
                };                        
            };
        };
    };

    public func getAuthorized(authorized : HashMap.HashMap<Principal,  HashMap.HashMap<Principal, [NftTypes.Token]>> ,owner : Principal, id : Text) : [NftTypes.AuthorizeInfo] {
        switch (authorized.get(owner)) {
            case (?subMap) {
                var tmp :[NftTypes.AuthorizeInfo] = [];
                for((p, tokens) in subMap.entries()){
                    switch(Array.find<NftTypes.Token>(tokens, func(v){v.id == id})){
                        case null {};
                        case (?v){
                            let a : NftTypes.AuthorizeInfo = {
                                amount = v.amount;
                                id = v.id;
                                user = p;
                            };
                            tmp := Array.append<(NftTypes.AuthorizeInfo)>(tmp,[a]);
                        };
                    };
                };
                return tmp;
            };
            case _ return [];
        };
    };

}
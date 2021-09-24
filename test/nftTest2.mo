import nft "../src/nft";
import NftTypes "../src/types";
import Debug "mo:base/Debug";
import Principal "mo:base/Principal";
import Array "mo:base/Array";
import Result "mo:base/Result";
import Cycles "mo:base/ExperimentalCycles";
import Blob "mo:base/Blob";
import Nat8 "mo:base/Nat8";
import Nat "mo:base/Nat";
import Error "mo:base/Error";
import Nat32 "mo:base/Nat32";


actor class nftTest2() = this {
    public func test(nftActor : Principal, amount : Nat, mintID : Text, payload : [Nat8], from : Principal) : async (Nat){
        try {
            let self = Principal.fromActor(this);
            let actorNft = actor(Principal.toText(nftActor)) : nft.Nft; 

            // transfer
            let trsq : NftTypes.TransferRequest = {
                from = from;
                to = self;
                id = [mintID];
                amount = [amount/3];
            };
            let trsRet = await actorNft.transferFrom(trsq);
            switch(trsRet){
                case (#ok()){};
                case (#err(e))(assert(false));
            };

            let balance1 = await actorNft.balanceOf(trsq.to, mintID);
            var trsfAmount = 0;
            for( a in trsq.amount.vals()){
                trsfAmount += a;
            };
            assert(trsfAmount == balance1);
            // do {
            //     let auths = await actorNft.getAuthorized(authorTo, mintID);
            //     assert(auths.size() == 0);
            // };

            let ownerRet = await actorNft.ownerOf(mintID);
            switch (ownerRet){
                case (#ok(owners)){
                    assert(owners[0] == trsq.to or owners[1] == trsq.to);
                };
                case (#err(v)){assert(false)};
            };  
            
            // query
            switch (await actorNft.tokenByID(mintID)){
                case (#ok(nft)){      
                    assert(nft.owners.size() == 2);

                    let retPayload = switch(nft.payload){
                        case (#Complete(v)){v;};
                        case (#Chunk(v)){
                            // to do check all data
                            v.data;
                        };
                    };
                    
                    assert(Array.equal<Nat8>(payload, Blob.toArray(retPayload), func(a : Nat8, b : Nat8): Bool{
                        return Nat8.equal(a, b);
                    }));                    
                };
                case (#err(e)){
                    assert(false);
                };
            };

            // Properties
        
            // burn
            do {
                try {
                    let retBurn = await actorNft.burn(mintID, amount + 1);
                    switch(retBurn){
                        case (#ok){assert(false)};
                        case (#err(v)){assert(false)};
                    };
                } catch (e){
                    Debug.print(debug_show("ignore burn exception", Error.message(e)));
                };
            };
         
            let burnAmount =  amount/4;
            do{
                try{
                    let retBurn = await actorNft.burn(mintID, burnAmount);
                    switch(retBurn){
                        case (#ok){ };
                        case (#err(v)){ assert(false);};
                    };
                } catch (e){
                    //Debug.print(debug_show("should burn exception", Error.message(e)));
                };
            };

            // check 
            do{
                let (totalMinted, totalNfts) = await actorNft.getTotalMinted();
                Debug.print(debug_show("nft class:",totalMinted,"totalMintNfts:", amount,"totalNfts:", totalNfts ,"burnAmount:", burnAmount));
                assert(totalMinted == 1 and amount == totalNfts + burnAmount);
            };

            return burnAmount;
        } catch (e){
            Debug.print(debug_show("exception", Error.message(e)));
            return 0;
        }
    }
}
import Result "mo:base/Result";
module {
    public type Callback = shared () -> async ();
    public func notify(callback : ?Callback) : async () {
        switch(callback) {
            case null   return;
            case (? cb) {ignore cb()};
        };
    };

    public type StagedWrite = {
        #Init : {
            size     : Nat; 
            callback : ?Callback};
        #Chunk : {
            chunk    : Blob; 
            callback : ?Callback
        };
    };

    public type Error = {
        #Unauthorized;
        #NotFound;
        #InvalidRequest;
        #AuthorizedPrincipalLimitReached : Nat;
    };
}
import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Buffer "mo:base/Buffer";
import HashMap "mo:base/HashMap";
import Http "http";
import Iter "mo:base/Iter";
import Text "mo:base/Text";
import Types "types";

module Static {
    public type Asset = {
        contentType : Text;
        payload     : [Blob];
    };

    public type AssetRequest = {
        // Remove asset with the given name.
        #Remove : {
            key      : Text;
            callback : ?Types.Callback;
        };
        // Inserts/Overwrites the asset.
        #Put : {
            key         : Text;
            contentType : Text;
            payload : {
                #Payload : Blob;
                // Uses the staged data that was written by #StagedWrite.
                #StagedData;
            };
            callback : ?Types.Callback;
        };
        // Stage (part of) an asset.
        #StagedWrite : Types.StagedWrite;
    };

    public class Assets(
        assetEntries: [(
            Text,        // Asset Identifier (path).
            Static.Asset // Asset data.
        )],
    ) {
        var stagedData = Buffer.Buffer<Blob>(0);

        let assets = HashMap.fromIter<Text, Asset>(
            assetEntries.vals(),
            assetEntries.size(),
            Text.equal,
            Text.hash,
        );

        public func entries() : Iter.Iter<(Text, Asset)> {
            return assets.entries();
        };

        public func getToken(id : Text) : ?Asset {
            assets.get(id);
        };

        // Returns a list of all static assets.
        public func list() : [(
            Text, // Name (key).
            Text, // Content type.
            Nat,  // Total size (number of bytes) of the payload.
        )] {
            let listAssets = Array.init<(Text, Text, Nat)>(
                assets.size(), ("", "", 0),
            );
            var i = 0;
            for ((k, v) in assets.entries()) {
                listAssets[i] := (
                    k,
                    v.contentType,
                    sum(v.payload.vals()),
                );
                i += 1;
            };
            return Array.freeze(listAssets);
        };

        // Returns a static asset based on the given key (path).
        // If the path is not found `index.html` gets returned (if defined).
        //
        // Limitation: callback is a shared function and is only allowed as a public field of an actor.
        public func get(key : Text, callback : Http.StreamingCallback) : Http.Response {
            switch(assets.get(key)) {
                case null {
                    // If the path was 'index.html' and it was not found, return 404.
                    if (key == "/index.html") return Http.NOT_FOUND();
                    // Otherwise return the index page.
                    return get("/index.html", callback);
                };
                case (?asset) {
                    if (asset.payload.size() == 1) {
                        return {
                            body               = asset.payload[0];
                            headers            = [("Content-Type", asset.contentType)];
                            status_code        = 200;
                            streaming_strategy = null;
                        };
                    };
                    // Content is devided in chunks.
                    Http.handleLargeContent(
                        key,
                        asset.contentType,
                        asset.payload,
                        callback,
                    );
                };
            };
        };

        // Handles the given asset request, see AssetRequest for possible actions.
        public func handleRequest(data : AssetRequest) : async () {
            switch(data) {
                case(#Put(v)) {
                    switch(v.payload) {
                        case(#Payload(data)) {
                            assets.put(
                                v.key,
                                {
                                    contentType = v.contentType;
                                    payload     = [data];
                                },
                            );
                        };
                        case (#StagedData) {
                            assets.put(
                                v.key,
                                {
                                    contentType = v.contentType;
                                    payload     = stagedData.toArray();
                                },
                            );
                            // Reset staged data.
                            stagedData := Buffer.Buffer(0);
                        };
                    };
                    ignore Types.notify(v.callback);
                };

                case(#Remove(v)) {
                    assets.delete(v.key);
                    ignore Types.notify(v.callback);
                };

                case(#StagedWrite(v)) {
                    switch(v) {
                        case (#Init(v)) {
                            stagedData := Buffer.Buffer(v.size);
                            ignore Types.notify(v.callback);
                        };
                        case (#Chunk(v)) {
                            stagedData.add(v.chunk);
                            ignore Types.notify(v.callback);
                        };
                    };
                };
            };
        };

        // Returns the total length of the list of blobs.
        private func sum(bs : Iter.Iter<Blob>) : Nat {
            var sum = 0;
            Iter.iterate<Blob>(bs, func(x,_) {
                sum += x.size();
            });
            sum;
        };
    };
}

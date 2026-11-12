import Foundation
import CommonCrypto

// Request signing only; no protected-audio decoding. Adapted from TuneWeave
// (MOPELotus, MIT); its complete notice is in the bundled licenses.
enum NativeKuwoCrypto {
    static let material=Data("$Aivn&2@BZ*A$qsv".utf8)
    static func digest(_ input:Data)->String {
        let shifts:[UInt32]=[7,12,17,22,5,9,14,20,4,11,16,23,6,10,15,21]
        var bytes=Array("k!^E6Ks1".utf8)+Array(input)
        let bits=UInt64(bytes.count)*8
        bytes.append(128)
        while bytes.count%64 != 56{bytes.append(0)}
        bytes+=(0..<8).map{UInt8(truncatingIfNeeded:bits>>UInt64($0*8))}
        var state:[UInt32]=[0x67452301,0xefcdab89,0x98badcfe,0x10325476]
        for offset in stride(from:0,to:bytes.count,by:64) {
            let words:[UInt32]=(0..<16).map {i in
                let k=offset+i*4
                return UInt32(bytes[k]) | UInt32(bytes[k+1])<<8 | UInt32(bytes[k+2])<<16 | UInt32(bytes[k+3])<<24
            }
            var a=state[0],b=state[1],c=state[2],d=state[3]
            for i in 0..<64 {
                let f:UInt32,g:Int
                if i<16{f=(b&c)|(~b&d);g=i}
                else if i<32{f=(d&b)|(~d&c);g=(5*i+1)%16}
                else if i<48{f=b^c^d;g=(3*i+5)%16}
                else{f=c^(b | ~d);g=(7*i)%16}
                var n=a &+ f &+ 0xd76aa478 &+ words[g]
                let shift=shifts[(i/16)*4+i%4]
                n=(n<<shift)|(n>>(32-shift))
                (a,b,c,d)=(d,b &+ n,b,c)
            }
            for (index,value) in [a,b,c,d].enumerated(){state[index]=state[index] &+ value}
        }
        return state.flatMap{value in (0..<4).map{UInt8(truncatingIfNeeded:value>>UInt32($0*8))}}.map{String(format:"%02x",$0)}.joined()
    }
    static func encrypt(_ plain:Data,material:Data=material) throws->String {
        if plain.isEmpty{return ""}
        let key=Data(digest(material).utf8.dropFirst(7).prefix(16))
        var output=[UInt8](repeating:0,count:plain.count+kCCBlockSizeAES128),written=0
        let capacity=output.count
        let status=key.withUnsafeBytes {keyBytes in plain.withUnsafeBytes {bytes in output.withUnsafeMutableBytes {out in
            CCCrypt(CCOperation(kCCEncrypt),CCAlgorithm(kCCAlgorithmAES),CCOptions(kCCOptionECBMode|kCCOptionPKCS7Padding),keyBytes.baseAddress,key.count,nil,bytes.baseAddress,plain.count,out.baseAddress,capacity,&written)
        }}}
        guard status==kCCSuccess else{throw EngineFailure(reason:"酷我请求签名未能完成。",code:"account_response")}
        return Data(output.prefix(written)).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:".")
    }
    static func percent(_ value:String)->String {
        let allowed=Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!$'*-._".utf8)
        return value.utf8.map{allowed.contains($0) ? String(UnicodeScalar($0)) : String(format:"%%%02X",$0)}.joined()
    }
    static func seal(_ fields:[String:String]) throws->String {
        guard fields.count<=64,fields["kwsign"]==nil else{throw EngineFailure(reason:"酷我授权参数无效。",code:"account_response")}
        var values=fields;values["kpk"]="a26692b114b983a72a19db4d6ce652bf";values["kwso"]="kwplayer_ar"
        let pairs=values.keys.sorted().map{$0+(values[$0] ?? "")}.joined()
        values["kwsign"]=digest(material+Data(pairs.utf8)+Data("/mobi.s".utf8))
        let plain=Data(values.keys.sorted().map{percent($0)+"="+percent(values[$0] ?? "")}.joined(separator:"&").utf8)
        guard plain.count<=32768 else{throw EngineFailure(reason:"酷我授权参数过长。",code:"account_response")}
        return try encrypt(plain)
    }
}

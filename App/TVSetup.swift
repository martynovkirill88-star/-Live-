import SwiftUI
import WebKit
import Network
import CryptoKit
import SwiftADB
import ADBPairing

struct AndroidTVSetupView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { TVInstallBrowser(close:{dismiss()}).navigationBarHidden(true).ignoresSafeArea(edges:.bottom) }
}
private struct TVInstallBrowser: UIViewRepresentable {
    let close:()->Void
    func makeCoordinator()->Coordinator{Coordinator(close:close)}
    func makeUIView(context:Context)->WKWebView{
        let config=WKWebViewConfiguration();config.userContentController.add(context.coordinator,name:"tv")
        let view=WKWebView(frame:.zero,configuration:config);view.isOpaque=false;view.backgroundColor=UIColor(red:10/255,green:16/255,blue:17/255,alpha:1)
        view.navigationDelegate=context.coordinator;context.coordinator.web=view
        if let folder=Bundle.main.url(forResource:"TVSetupPage",withExtension:nil){view.loadFileURL(folder.appendingPathComponent("index.html"),allowingReadAccessTo:folder)}
        return view
    }
    func updateUIView(_ view:WKWebView,context:Context){}
    static func dismantleUIView(_ view:WKWebView,coordinator:Coordinator){coordinator.stop();view.configuration.userContentController.removeScriptMessageHandler(forName:"tv")}
    final class Coordinator:NSObject,WKScriptMessageHandler,WKNavigationDelegate,NetServiceBrowserDelegate,NetServiceDelegate {
        weak var web:WKWebView?
        let close:()->Void
        var connection:AdbConnection?
        var operation:Task<Void,Never>?
        var browsers=[NetServiceBrowser](),services=[NetService](),seen=Set<String>()
        init(close:@escaping()->Void){self.close=close}
        func event(_ data:[String:Any]){
            DispatchQueue.main.async{[weak self] in guard let self,let web=self.web,web.url?.isFileURL==true,let raw=try? JSONSerialization.data(withJSONObject:data),let json=String(data:raw,encoding:.utf8) else{return};web.evaluateJavaScript("window.onTVEvent?.(\(json))",completionHandler:nil)}
        }
        func status(_ text:String,type:String="status"){event(["type":type,"message":text])}
        static func local(_ value:String)->Bool{
            let parts=value.split(separator:".");guard parts.count==4 else{return false}
            let n=parts.compactMap{Int($0)};guard n.count==4,n.allSatisfy({0...255 ~= $0}) else{return false}
            return n[0]==10 || (n[0]==192&&n[1]==168) || (n[0]==172&&(16...31).contains(n[1]))
        }
        func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage){
            guard message.frameInfo.isMainFrame,web?.url?.isFileURL==true,let data=message.body as? [String:Any],let action=data["action"] as? String else{return}
            if action=="scan"{scan();return}
            if action=="disconnect"{stop();status("Телевизор отключён. Можно выключить отладку на ТВ.",type:"disconnected");return}
            if action=="close"{stop();close();return}
            guard operation==nil else{return}
            operation=Task{@MainActor [weak self] in
                guard let self else{return};defer{self.operation=nil}
                do{
                    switch action{
                    case "connect":
                        guard let host=data["host"] as? String,Self.local(host),let port=data["port"] as? Int,(1...65535).contains(port) else{throw self.failure("Введите локальный IP и порт телевизора.")}
                        await self.connection?.close();let key=try TVADBIdentity.load();let code=data["code"] as? String ?? ""
                        if !code.isEmpty{
                            guard code.count==6,code.allSatisfy({$0.isASCII&&$0.isNumber}),let pairPort=data["pairPort"] as? Int,(1...65535).contains(pairPort) else{throw self.failure("Введите шестизначный код и порт сопряжения с ТВ.")}
                            self.status("Подтверждаем код сопряжения…")
                            let pairing=ADBPairingConnection(host:host,port:UInt16(pairPort),password:code,keyPair:key,deviceName:"Chepushka Live iPhone")
                            _ = try await pairing.pair()
                        }
                        self.status("Подтвердите разрешение отладки на телевизоре, если оно появится.")
                        let connection=AdbConnection(host:host,port:UInt16(port),keyPair:key,api:code.isEmpty ? 28:33,deviceName:"Chepushka Live iPhone")
                        self.connection=connection
                        guard try await connection.connect(timeout:45,throwOnUnauthorised:false,useTls:!code.isEmpty) else{throw self.failure("Телевизор не подтвердил подключение.")}
                        let model=try await self.shell("getprop ro.product.model").trimmingCharacters(in:.whitespacesAndNewlines)
                        self.status("Подключено: "+model,type:"connected")
                    case "install":
                        guard let product=data["product"] as? String,["rustore","live"].contains(product),self.connection != nil else{throw self.failure("Сначала подключитесь к телевизору.")}
                        try await self.install(product)
                    case "launch":
                        _ = try await self.shell("am start -n fun.chepushkavpn.live/.TVActivity");self.status("Чепушка Live открыта на телевизоре.")
                    default:break
                    }
                }catch{if !Task.isCancelled{self.status(error.localizedDescription,type:"error")}}
            }
        }
        func failure(_ text:String)->NSError{NSError(domain:"TVSetup",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
        func shell(_ command:String)async throws->String{
            guard let connection else{throw failure("Подключитесь к телевизору.")}
            let stream=try await connection.open(destination:"shell:"+command)
            defer{Task{try? await stream.close()}}
            return try await read(stream)
        }
        func read(_ stream:AdbStream)async throws->String{
            var result=Data()
            while true{
                let block:Data
                do{block=try await stream.read()}catch ADBError.streamClosed{break}
                if block.isEmpty{break};result.append(block);if result.count>65536{throw failure("Некорректный ответ телевизора.")}
            }
            return String(decoding:result,as:UTF8.self)
        }
        private struct Release:Decodable{let url:String;let sha256:String;let size:Int}
        func install(_ product:String)async throws{
            guard let connection else{throw failure("Подключитесь к телевизору.")}
            let (data,response)=try await URLSession.shared.data(from:URL(string:"https://live.chepushkavpn.fun/tv-install/releases.json")!)
            guard (response as? HTTPURLResponse)?.statusCode==200,data.count<65536,let release=try JSONDecoder().decode([String:Release].self,from:data)[product],let url=URL(string:release.url),url.scheme=="https",url.host=="live.chepushkavpn.fun",url.path.hasPrefix("/tv-install/files/"),(1...150*1024*1024).contains(release.size) else{throw failure("Не удалось получить актуальный установщик.")}
            status("Скачиваем "+(product=="rustore" ? "RuStore":"Чепушку Live")+"…")
            let (download,fileResponse)=try await URLSession.shared.download(from:url)
            guard (fileResponse as? HTTPURLResponse)?.statusCode==200,fileResponse.url?.host==url.host else{throw failure("Не удалось скачать установщик.")}
            let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".apk")
            try FileManager.default.moveItem(at:download,to:file);defer{try? FileManager.default.removeItem(at:file)}
            let bytes=try Data(contentsOf:file,options:.mappedIfSafe)
            guard bytes.count==release.size,SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()==release.sha256 else{throw failure("Файл не прошёл проверку целостности. Повторите загрузку.")}
            status("Устанавливаем. Подтвердите запрос на ТВ, если он появится.")
            let stream=try await connection.open(destination:"exec:cmd package install -r -S \(bytes.count)")
            defer{Task{try? await stream.close()}}
            let chunk=max(1,min(65536,Int(await connection.getMaxData())));var offset=0;var last=Date.distantPast
            while offset<bytes.count{
                try Task.checkCancellation();let end=min(bytes.count,offset+chunk)
                try await stream.write(bytes.subdata(in:offset..<end));offset=end
                if Date().timeIntervalSince(last)>0.2{event(["type":"progress","step":"install","current":offset,"total":bytes.count]);last=Date()}
            }
            let result=try await read(stream)
            guard result.contains("Success") else{throw failure("Телевизор отклонил установку: "+String(result.prefix(250)))}
            status(product=="rustore" ? "RuStore установлен. Теперь можно установить Чепушку Live.":"Чепушка Live установлена. Можно открыть её на ТВ.",type:product=="rustore" ? "rustore-installed":"live-installed")
        }
        func scan(){
            stopBrowsers();seen.removeAll();status("Ищем Android TV в вашей Wi-Fi сети…",type:"scanning")
            for type in ["_adb._tcp.","_adb-tls-connect._tcp.","_adb-tls-pairing._tcp.","_androidtvremote2._tcp."]{let browser=NetServiceBrowser();browser.delegate=self;browsers.append(browser);browser.searchForServices(ofType:type,inDomain:"local.")}
            DispatchQueue.main.asyncAfter(deadline:.now()+12){[weak self] in guard let self,!self.browsers.isEmpty else{return};self.stopBrowsers();self.status(self.seen.isEmpty ? "Не найдено. Включите отладку на ТВ и повторите поиск или введите IP вручную.":"Выберите свой телевизор. Порты сопряжения и подключения различаются.",type:"scan-complete")}
        }
        func netServiceBrowser(_ browser:NetServiceBrowser,didFind service:NetService,moreComing:Bool){services.append(service);service.delegate=self;service.resolve(withTimeout:6)}
        func netServiceDidResolveAddress(_ sender:NetService){
            for address in sender.addresses ?? []{
                var host=[CChar](repeating:0,count:Int(NI_MAXHOST))
                let success=address.withUnsafeBytes{raw in getnameinfo(raw.baseAddress!.assumingMemoryBound(to:sockaddr.self),socklen_t(address.count),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST)}
                guard success==0 else{continue};let ip=String(cString:host);guard Self.local(ip) else{continue}
                let kind=sender.type.contains("pairing") ? "pairing":sender.type.contains("tls-connect") ? "tls":"tcp"
                let port=sender.type.contains("androidtvremote") ? 5555:sender.port;let key="\(ip):\(port):\(kind)"
                if seen.insert(key).inserted{event(["type":"device","name":sender.name,"host":ip,"port":port,"kind":kind])}
            }
        }
        func stopBrowsers(){for b in browsers{b.stop()};browsers.removeAll();for s in services{s.stop()};services.removeAll()}
        func stop(){stopBrowsers();operation?.cancel();operation=nil;let previous=connection;connection=nil;Task{await previous?.close()}}
        func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){
            guard let url=action.request.url else{decisionHandler(.cancel);return}
            if url.isFileURL{decisionHandler(.allow);return}
            if action.navigationType == .linkActivated,url.scheme=="https"{UIApplication.shared.open(url)}
            decisionHandler(.cancel)
        }
    }
}

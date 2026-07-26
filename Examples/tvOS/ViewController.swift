/*
 Copyright (c) 2012-2019, Pierre-Olivier Latour
 All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * The name of Pierre-Olivier Latour may not be used to endorse
 or promote products derived from this software without specific
 prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL PIERRE-OLIVIER LATOUR BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

import Serve
import UIKit

class ViewController: UIViewController {
  @IBOutlet var label: UILabel?
  var webServer: SRVUploader!

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)

    let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
    webServer = SRVUploader(uploadDirectory: documentsPath)
    webServer.delegate = self

    // The server is reachable by anything on the same network. To require a password,
    // and/or to accept connections from this device only, start it with options instead:
    //
    // try? webServer.start(options: [
    //   SRVOption_AuthenticationMethod: SRVAuthenticationMethod_Basic,
    //   SRVOption_AuthenticationAccounts: ["user": "password"],
    //   SRVOption_BindToLocalhost: true,
    // ])
    if webServer.start() {
      label?.text = "SRVServer running locally on port \(webServer.port)"
    } else {
      label?.text = "SRVServer not running!"
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)

    webServer.stop()
    webServer = nil
  }
}

extension ViewController: SRVUploaderDelegate {
  func webUploader(_: SRVUploader, didUploadFileAtPath path: String) {
    print("[UPLOAD] \(path)")
  }

  func webUploader(_: SRVUploader, didDownloadFileAtPath path: String) {
    print("[DOWNLOAD] \(path)")
  }

  func webUploader(_: SRVUploader, didMoveItemFromPath fromPath: String, toPath: String) {
    print("[MOVE] \(fromPath) -> \(toPath)")
  }

  func webUploader(_: SRVUploader, didCreateDirectoryAtPath path: String) {
    print("[CREATE] \(path)")
  }

  func webUploader(_: SRVUploader, didDeleteItemAtPath path: String) {
    print("[DELETE] \(path)")
  }
}

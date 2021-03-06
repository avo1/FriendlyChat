//
//  Copyright (c) 2015 Google Inc.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import UIKit
import Firebase
import FirebaseAuthUI
import FirebaseGoogleAuthUI

// MARK: - FCViewController

class FCViewController: UIViewController, UINavigationControllerDelegate {
    
    // MARK: Properties
    
    var ref: DatabaseReference!
    var messages: [DataSnapshot]! = []
    var msglength: NSNumber = 1000
    var storageRef: StorageReference!
    var remoteConfig: RemoteConfig!
    let imageCache = NSCache<NSString, UIImage>()
    var keyboardOnScreen = false
    var placeholderImage = UIImage(named: "ic_account_circle")
    fileprivate var _refHandle: DatabaseHandle!
    fileprivate var _authHandle: AuthStateDidChangeListenerHandle!
    var user: User?
    var displayName = "Anonymous"
    
    // MARK: Outlets
    
    @IBOutlet weak var messageTextField: UITextField!
    @IBOutlet weak var sendButton: UIButton!
    @IBOutlet weak var signInButton: UIButton!
    @IBOutlet weak var imageMessage: UIButton!
    @IBOutlet weak var signOutButton: UIButton!
    @IBOutlet weak var messagesTable: UITableView!
    @IBOutlet weak var backgroundBlur: UIVisualEffectView!
    @IBOutlet weak var imageDisplay: UIImageView!
    @IBOutlet var dismissImageRecognizer: UITapGestureRecognizer!
    @IBOutlet var dismissKeyboardRecognizer: UITapGestureRecognizer!
    
    // MARK: Life Cycle
    
    override func viewDidLoad() {
        configureAuth()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        unsubscribeFromAllNotifications()
    }
    
    // MARK: Config
    
    func configureAuth() {
        let providers: [FUIAuthProvider]! = [FUIGoogleAuth()]
        FUIAuth.defaultAuthUI()?.providers = providers
        
        // listen to the change on the authentication state
        _authHandle = Auth.auth().addStateDidChangeListener({ (auth: Auth, user: User?) in
            // refresh table data
            self.messages.removeAll(keepingCapacity: false)
            self.messagesTable.reloadData()
            
            // is there a current user?
            if let activeUser = user {
                // is this the diff user from user in the app?
                if self.user != activeUser {
                    self.user = activeUser
                    self.signedInStatus(isSignedIn: true)
                    self.displayName = (activeUser.email?.components(separatedBy: "@")[0])!
                }
            } else {
                // user must sign in
                self.signedInStatus(isSignedIn: false)
                self.loginSession()
            }
        })
    }
    
    func configureDatabase() {
        ref = Database.database().reference()
        _refHandle = ref.child("messages").observe(.childAdded, with: { (snapshot) in
            self.messages.append(snapshot)
            self.messagesTable.insertRows(at: [IndexPath(row: self.messages.count - 1, section: 0)], with: UITableViewRowAnimation.automatic)
            self.scrollToBottomMessage()
        })
    }
    
    func configureStorage() {
        storageRef = Storage.storage().reference()
        
    }
    
    deinit {
        // remove the observer when no longer in need, as it's not automatically
        ref.child("messages").removeObserver(withHandle: _refHandle)
        Auth.auth().removeStateDidChangeListener(_authHandle)
    }
    
    // MARK: Remote Config
    
    func configureRemoteConfig() {
        let remoteConfigSetting = RemoteConfigSettings(developerModeEnabled: true)
        remoteConfig = RemoteConfig.remoteConfig()
        remoteConfig.configSettings = remoteConfigSetting!
    }
    
    func fetchConfig() {
        var expirationDuration: Double = 3600 //60'
        
        if remoteConfig.configSettings.isDeveloperModeEnabled {
            // get the new configuration immediatelly
            expirationDuration = 0
        }
        
        remoteConfig.fetch(withExpirationDuration: expirationDuration) { (status, error) in
            if let error = error {
                print("error fetching config: \(error.localizedDescription)")
                return
            }
            
            if status == .success {
                print("config fetched")
                self.remoteConfig.activateFetched()
                let maxLength = self.remoteConfig["max_message_length"]
                if maxLength.source != .static {
                    self.msglength = maxLength.numberValue!
                }
            }
        }
    }
    
    // MARK: Sign In and Out
    
    func signedInStatus(isSignedIn: Bool) {
        signInButton.isHidden = isSignedIn
        signOutButton.isHidden = !isSignedIn
        messagesTable.isHidden = !isSignedIn
        messageTextField.isHidden = !isSignedIn
        sendButton.isHidden = !isSignedIn
        imageMessage.isHidden = !isSignedIn
        
        if (isSignedIn) {
            
            // remove background blur (will use when showing image messages)
            messagesTable.rowHeight = UITableViewAutomaticDimension
            messagesTable.estimatedRowHeight = 122.0
            backgroundBlur.effect = nil
            messageTextField.delegate = self
            
            configureDatabase()
            configureStorage()
            configureRemoteConfig()
            fetchConfig()
        }
    }
    
    func loginSession() {
        let authViewController = FUIAuth.defaultAuthUI()!.authViewController()
        self.present(authViewController, animated: true, completion: nil)
    }
    
    // MARK: Send Message
    
    func sendMessage(data: [String: String]) {
        var mdata = data
        mdata[Constants.MessageFields.name] = displayName
        ref.child("messages").childByAutoId().setValue(mdata)
    }
    
    func sendPhotoMessage(photoData: Data) {
        // set the image path, 1 folder for each user
        let imagePath = "ChatPhotos/" + (user?.uid)! + "/" + "\(Double(Date.timeIntervalSinceReferenceDate * 1000))" + ".jpg"
        
        // set the content type of metadata
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        
        // create a child node at image path
        storageRef.child(imagePath).putData(photoData, metadata: metadata) { (metadata, error) in
            if let error = error {
                print("upload failed: \(error.localizedDescription)")
                return
            }
            
            self.sendMessage(data: [Constants.MessageFields.imageUrl: self.storageRef.child((metadata?.path)!).description])
            
        }
        
    }
    
    // MARK: Alert
    
    func showAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            let dismissAction = UIAlertAction(title: "Dismiss", style: .destructive, handler: nil)
            alert.addAction(dismissAction)
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    // MARK: Scroll Messages
    
    func scrollToBottomMessage() {
        if messages.count == 0 { return }
        let bottomMessageIndex = IndexPath(row: messagesTable.numberOfRows(inSection: 0) - 1, section: 0)
        messagesTable.scrollToRow(at: bottomMessageIndex, at: .bottom, animated: true)
    }
    
    // MARK: Actions
    
    @IBAction func showLoginView(_ sender: AnyObject) {
        loginSession()
    }
    
    @IBAction func didTapAddPhoto(_ sender: AnyObject) {
        let picker = UIImagePickerController()
        picker.delegate = self
        picker.sourceType = .photoLibrary
        present(picker, animated: true, completion: nil)
    }
    
    @IBAction func signOut(_ sender: UIButton) {
        do {
            try Auth.auth().signOut()
        } catch {
            print("unable to sign out: \(error)")
        }
    }
    
    @IBAction func didSendMessage(_ sender: UIButton) {
        let _ = textFieldShouldReturn(messageTextField)
        messageTextField.text = ""
    }
    
    @IBAction func dismissImageDisplay(_ sender: AnyObject) {
        // if touch detected when image is displayed
        if imageDisplay.alpha == 1.0 {
            UIView.animate(withDuration: 0.25) {
                self.backgroundBlur.effect = nil
                self.imageDisplay.alpha = 0.0
            }
            dismissImageRecognizer.isEnabled = false
            messageTextField.isEnabled = true
        }
    }
    
    @IBAction func tappedView(_ sender: AnyObject) {
        resignTextfield()
    }
}

// MARK: - FCViewController: UITableViewDelegate, UITableViewDataSource

extension FCViewController: UITableViewDelegate, UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return messages.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // dequeue cell
        let cell: UITableViewCell! = messagesTable.dequeueReusableCell(withIdentifier: "messageCell", for: indexPath)
        
        let msgSnapshot: DataSnapshot! = messages[indexPath.row]
        let message = msgSnapshot.value as! [String: String]
        let name = message[Constants.MessageFields.name] ?? "[User]"
        
        if let imageUrl = message[Constants.MessageFields.imageUrl] {
            cell.textLabel?.text = "sent by " + name
            // download and display image
            Storage.storage().reference(forURL: imageUrl).getData(maxSize: INT64_MAX, completion: { (imageData, error) in
                if let error = error {
                    print("download image failed: \(error.localizedDescription)")
                    return
                }
                
                let img = UIImage(data: imageData!, scale: 50)
                self.imageCache.setObject(img!, forKey: imageUrl as NSString)
                
                // check if the cell is still on the screen, if so set the image
                if cell == self.messagesTable.cellForRow(at: indexPath) {
                    DispatchQueue.main.async {
                        cell.imageView?.image = img
                        cell.setNeedsLayout()
                    }
                }
            })
        } else {
            let text = message[Constants.MessageFields.text] ?? "[message]"
            
            cell.textLabel?.text = name + ": " + text
            cell.imageView?.image = placeholderImage
        }
        return cell!
    }
    
    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableViewAutomaticDimension
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // if message contains an image, then display the image
        // skip if keyboard is shown
        guard !messageTextField.isFirstResponder else { return }
        
        // unpack message from firebase data snapshot
        let messageSnapshot: DataSnapshot! = messages[indexPath.row]
        let message = messageSnapshot.value as! [String: String]
        if let imageUrl = message[Constants.MessageFields.imageUrl] {
            if let cachedImage = imageCache.object(forKey: imageUrl as NSString) {
                showImageDisplay(cachedImage)
            } else {
                Storage.storage().reference(forURL: imageUrl).getData(maxSize: INT64_MAX){ (data, error) in
                    guard error == nil else {
                        print("Error downloading: \(error!)")
                        return
                    }
                    self.showImageDisplay(UIImage.init(data: data!)!)
                }
            }
        }
    }
    
    // MARK: Show Image Display
    
    func showImageDisplay(_ image: UIImage) {
        dismissImageRecognizer.isEnabled = true
        dismissKeyboardRecognizer.isEnabled = false
        messageTextField.isEnabled = false
        UIView.animate(withDuration: 0.25) {
            self.backgroundBlur.effect = UIBlurEffect(style: .light)
            self.imageDisplay.alpha = 1.0
            self.imageDisplay.image = image
        }
    }
    
}

// MARK: - FCViewController: UIImagePickerControllerDelegate

extension FCViewController: UIImagePickerControllerDelegate {
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [String:Any]) {
        // constant to hold the information about the photo
        if let photo = info[UIImagePickerControllerOriginalImage] as? UIImage, let photoData = UIImageJPEGRepresentation(photo, 0.8) {
            // call function to upload photo message
            sendPhotoMessage(photoData: photoData)
        }
        picker.dismiss(animated: true, completion: nil)
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true, completion: nil)
    }
}

// MARK: - FCViewController: UITextFieldDelegate

extension FCViewController: UITextFieldDelegate {
    
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        // set the maximum length of the message
        guard let text = textField.text else { return true }
        let newLength = text.utf16.count + string.utf16.count - range.length
        return newLength <= msglength.intValue
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if !textField.text!.isEmpty {
            let data = [Constants.MessageFields.text: textField.text! as String]
            sendMessage(data: data)
            textField.resignFirstResponder()
        }
        return true
    }
    
    // MARK: Show/Hide Keyboard
    
    func keyboardWillShow(_ notification: Notification) {
        if !keyboardOnScreen {
            self.view.frame.origin.y -= self.keyboardHeight(notification)
        }
    }
    
    func keyboardWillHide(_ notification: Notification) {
        if keyboardOnScreen {
            self.view.frame.origin.y += self.keyboardHeight(notification)
        }
    }
    
    func keyboardDidShow(_ notification: Notification) {
        keyboardOnScreen = true
        dismissKeyboardRecognizer.isEnabled = true
        scrollToBottomMessage()
    }
    
    func keyboardDidHide(_ notification: Notification) {
        dismissKeyboardRecognizer.isEnabled = false
        keyboardOnScreen = false
    }
    
    func keyboardHeight(_ notification: Notification) -> CGFloat {
        return ((notification as NSNotification).userInfo![UIKeyboardFrameBeginUserInfoKey] as! NSValue).cgRectValue.height
    }
    
    func resignTextfield() {
        if messageTextField.isFirstResponder {
            messageTextField.resignFirstResponder()
        }
    }
}

// MARK: - FCViewController (Notifications)

extension FCViewController {
    
    func subscribeToKeyboardNotifications() {
        subscribeToNotification(.UIKeyboardWillShow, selector: #selector(keyboardWillShow))
        subscribeToNotification(.UIKeyboardWillHide, selector: #selector(keyboardWillHide))
        subscribeToNotification(.UIKeyboardDidShow, selector: #selector(keyboardDidShow))
        subscribeToNotification(.UIKeyboardDidHide, selector: #selector(keyboardDidHide))
    }
    
    func subscribeToNotification(_ name: NSNotification.Name, selector: Selector) {
        NotificationCenter.default.addObserver(self, selector: selector, name: name, object: nil)
    }
    
    func unsubscribeFromAllNotifications() {
        NotificationCenter.default.removeObserver(self)
    }
}

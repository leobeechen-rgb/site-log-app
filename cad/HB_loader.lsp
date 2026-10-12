;;; ==========================================================
;;;  赫柏工具 自動更新載入器  HB_loader.lsp
;;;  只要裝這一個檔（APPLOAD → 啟動組），每次開 CAD 會：
;;;    1. 到 www.herfulsinsvip.com 下載最新版赫柏工具（約 1～2 秒）
;;;    2. 存在 %APPDATA%\Herfulsins\ 裡
;;;    3. 載入；沒有網路時就用上次下載的版本
;;;  之後赫柏工具有更新，重開 CAD 就是新版，不用再換檔。
;;; ==========================================================
(vl-load-com)

(defun hbl:dir (/ d)
  (setq d (strcat (getenv "APPDATA") "\\Herfulsins"))
  (if (not (vl-file-directory-p d)) (vl-mkdir d))
  (strcat d "\\"))

(defun hbl:name ()
  ;; AutoCAD 2021（R24）以後用 UTF-8 版，之前（例如 2016）用 Big5 版
  (if (>= (atof (getvar "ACADVER")) 24.0) "HB_tools_UTF8.lsp" "HB_tools.lsp"))

;;; 檢查下載下來的檔案是不是 LISP（不是網頁錯誤頁）
(defun hbl:ok-file (f / h l)
  (if (and f (findfile f) (setq h (open f "r")))
    (progn (setq l (read-line h)) (close h)
           (and l (> (vl-file-size f) 20000) (vl-string-search ";;;" l)))))

;;; 方法一：AutoCAD 內建的下載（Utility.GetRemoteFile）
(defun hbl:dl-acad (url / u r tmp)
  (setq u (vla-get-Utility (vla-get-ActiveDocument (vlax-get-acad-object))))
  (setq r (vl-catch-all-apply 'vla-GetRemoteFile (list u url 'tmp :vlax-true)))
  (if (and (not (vl-catch-all-error-p r)) tmp (hbl:ok-file tmp)) tmp))

;;; 方法二：Windows 的 WinHttp／MSXML
(defun hbl:dl-http (url out prog / x st r v ok)
  (setq r (vl-catch-all-apply
    (function (lambda ()
      (setq x (vlax-create-object prog))
      (vlax-invoke-method x 'Open "GET" url :vlax-false)
      (vlax-invoke-method x 'Send)
      (if (= (vlax-get-property x 'Status) 200)
        (progn
          (setq v (vlax-get-property x 'ResponseBody))
          (setq st (vlax-create-object "ADODB.Stream"))
          (vlax-put-property st 'Type 1)
          (vlax-invoke-method st 'Open)
          (vlax-invoke-method st 'Write v)
          (vlax-invoke-method st 'SaveToFile out 2)
          (vlax-invoke-method st 'Close)
          (setq ok T)))))))
  (if st (vl-catch-all-apply 'vlax-release-object (list st)))
  (if x (vl-catch-all-apply 'vlax-release-object (list x)))
  (if (and ok (hbl:ok-file out)) out))

(defun hbl:download (url out / f)
  (cond
    ((setq f (hbl:dl-acad url)) (vl-file-copy f out) (hbl:ok-file out))
    ((hbl:dl-http url out "WinHttp.WinHttpRequest.5.1") T)
    ((hbl:dl-http url out "MSXML2.ServerXMLHTTP.6.0") T)
    ((hbl:dl-http url out "MSXML2.XMLHTTP") T)))

(defun hbl:run (/ dir nm local tmp got)
  (setq dir (hbl:dir) nm (hbl:name) local (strcat dir nm) tmp (strcat dir "_new_" nm))
  (if (findfile tmp) (vl-file-delete tmp))
  (setq got (hbl:download (strcat "https://www.herfulsinsvip.com/cad/" nm "?t=" (rtos (getvar "CDATE") 2 6)) tmp))
  (if got
    (progn (if (findfile local) (vl-file-delete local)) (vl-file-rename tmp local)))
  (cond
    ((findfile local)
     (load local)
     (princ (if got "\n【赫柏】赫柏工具已更新到最新版。" "\n【赫柏】目前沒有網路，使用上次下載的赫柏工具。")))
    (T (princ "\n【赫柏】第一次使用需要網路下載赫柏工具，請連上網路後重開 CAD。")))
  (princ))

(hbl:run)
(princ)

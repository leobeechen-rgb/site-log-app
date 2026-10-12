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

(defun hbl:download (url out / x st ok r body)
  (setq r (vl-catch-all-apply
    (function (lambda ()
      (setq x (vlax-create-object "MSXML2.ServerXMLHTTP.6.0"))
      (vlax-invoke x 'setTimeouts 3000 3000 4000 8000)
      (vlax-invoke x 'open "GET" url :vlax-false)
      (vlax-invoke x 'send)
      ;; 確認拿到的是 LISP 檔，不是網頁錯誤頁
      (if (and (= (vlax-get x 'status) 200)
               (setq body (vlax-safearray->list (vlax-variant-value (vlax-get x 'responseBody))))
               (> (length body) 20000)
               (member (car body) '(59 239)))
        (progn
          (setq st (vlax-create-object "ADODB.Stream"))
          (vlax-put st 'Type 1)
          (vlax-invoke st 'Open)
          (vlax-invoke st 'Write (vlax-get x 'responseBody))
          (vlax-invoke st 'SaveToFile out 2)
          (vlax-invoke st 'Close)
          (setq ok T)))))))
  (if st (vl-catch-all-apply 'vlax-release-object (list st)))
  (if x (vl-catch-all-apply 'vlax-release-object (list x)))
  (and ok (not (vl-catch-all-error-p r))))

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

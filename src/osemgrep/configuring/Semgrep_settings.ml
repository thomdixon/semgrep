(* TODO use ATD to specify the settings file format *)
type t = {
  has_shown_metrics_notification : bool option;
  api_token : string option;
  anonymous_user_id : Uuidm.t;
}

let default_settings =
  {
    has_shown_metrics_notification = None;
    api_token = None;
    anonymous_user_id = Uuidm.v `V4;
  }

let t = ref default_settings
let ( let* ) = Result.bind

(* ultimately we should just use ATD to automatically read the settings.yml
   file by converting it first to json and then use ATDgen API *)
let of_yaml = function
  | `O data ->
      let has_shown_metrics_notification =
        List.assoc_opt "has_shown_metrics_notification" data
      and api_token = List.assoc_opt "api_token" data
      and anonymous_user_id = List.assoc_opt "anonymous_user_id" data in
      let* has_shown_metrics_notification =
        Option.fold ~none:(Ok None)
          ~some:(function
            | `Bool b -> Ok (Some b)
            | _else -> Error (`Msg "has shown metrics notification not a bool"))
          has_shown_metrics_notification
      in
      let* api_token =
        Option.fold ~none:(Ok None)
          ~some:(function
            | `String s -> Ok (Some s)
            | _else -> Error (`Msg "api token not a string"))
          api_token
      in
      let* anonymous_user_id =
        Option.fold
          ~none:(Error (`Msg "no anonymous user id"))
          ~some:(function
            | `String s ->
                Option.to_result ~none:(`Msg "not a valid UUID")
                  (Uuidm.of_string s)
            | _else -> Error (`Msg "anonymous user id is not a string"))
          anonymous_user_id
      in
      Ok { has_shown_metrics_notification; api_token; anonymous_user_id }
  | _else -> Error (`Msg "YAML not an object")

let to_yaml { has_shown_metrics_notification; api_token; anonymous_user_id } =
  `O
    ((match has_shown_metrics_notification with
     | None -> []
     | Some v -> [ ("has_shown_metrics_notification", `Bool v) ])
    @ (match api_token with
      | None -> []
      | Some v -> [ ("api_token", `String v) ])
    @ [ ("anonymous_user_id", `String (Uuidm.to_string anonymous_user_id)) ])

let settings = Semgrep_envvars.env.user_settings_file

let get_contents () =
  lazy
    (t :=
       try
         if
           Sys.file_exists (Fpath.to_string settings)
           && Unix.(stat (Fpath.to_string settings)).st_kind = Unix.S_REG
         then
           let data = File.read_file settings in
           match Yaml.of_string data with
           | Error _ ->
               Logs.warn (fun m ->
                   m "Bad settings format; %a will be overriden. Contents:\n%s"
                     Fpath.pp settings data);
               default_settings
           | Ok value -> (
               match of_yaml value with
               | Error (`Msg msg) ->
                   Logs.warn (fun m ->
                       m
                         "Bad settings format; %a will be overriden. Contents:\n\
                          %s"
                         Fpath.pp settings data);
                   Logs.info (fun m -> m "Decode error: %s" msg);
                   default_settings
               | Ok s -> s)
         else (
           Logs.warn (fun m ->
               m "Settings file %a does not exist or is not a regular file"
                 Fpath.pp settings);
           default_settings)
       with
       | Failure _ -> default_settings)

let save setting =
  let yaml = to_yaml setting in
  let str = Yaml.to_string_exn yaml in
  try
    let dir = Fpath.(to_string (parent settings)) in
    if not (Sys.file_exists dir) then Sys.mkdir dir 0o755;
    let tmp = Fpath.(settings + "tmp") in
    if Sys.file_exists (Fpath.to_string tmp) then
      Sys.remove (Fpath.to_string tmp);
    File.write_file tmp str;
    Unix.rename (Fpath.to_string tmp) (Fpath.to_string settings);
    t := setting;
    true
  with
  | Sys_error e ->
      Logs.warn (fun m ->
          m "Could not write settings file at %a: %s" Fpath.pp settings e);
      false

let get () =
  Lazy.force (get_contents ());
  !t

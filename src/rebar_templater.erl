%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009 Dave Smith (dizzyd@dizzyd.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------
-module(rebar_templater).

-export([new/4,
         list_templates/1]).

%% API for other utilities that need templating functionality
-export([resolve_variables/2,
         render/2]).

-include("rebar.hrl").

-define(TEMPLATE_RE, "^[^._].*\\.template\$").
-define(ERLYDTL_COMPILE_OPTS, [report_warnings, return_errors, {auto_escape, false}, {out_dir, false}]).

%% ===================================================================
%% Public API
%% ===================================================================

%% Apply a template
new(Template, Vars, Force, State) ->
    {AvailTemplates, Files} = find_templates(State),
    ?DEBUG("Looking for ~p~n", [Template]),
    case lists:keyfind(Template, 1, AvailTemplates) of
        false -> {not_found, Template};
        TemplateTup -> create(TemplateTup, Files, Vars, Force)
    end.

%% Give a list of templates with their expanded content
list_templates(State) ->
    {AvailTemplates, Files} = find_templates(State),
    [list_template(Files, Template) || Template <- AvailTemplates].

%% ===================================================================
%% Rendering API / legacy?
%% ===================================================================

%% Given a list of key value pairs, for each string value attempt to
%% render it using Dict as the context. Storing the result in Dict as Key.
%%
resolve_variables([], Dict) ->
    Dict;
resolve_variables([{Key, Value0} | Rest], Dict) when is_list(Value0) ->
    Value = render(Value0, Dict),
    resolve_variables(Rest, dict:store(Key, Value, Dict));
resolve_variables([{Key, {list, Dicts}} | Rest], Dict) when is_list(Dicts) ->
    %% just un-tag it so erlydtl can use it
    resolve_variables(Rest, dict:store(Key, Dicts, Dict));
resolve_variables([_Pair | Rest], Dict) ->
    resolve_variables(Rest, Dict).

%%
%% Render a binary to a string, using erlydtl and the specified context
%%
render(Template, Context) when is_atom(Template) ->
    Template:render(Context);
render(Template, Context) ->
    Module = list_to_atom(Template++"_dtl"),
    Module:render(Context).


%% ===================================================================
%% Internal Functions
%% ===================================================================

%% Expand a single template's value
list_template(Files, {Name, Type, File}) ->
    TemplateTerms = consult(load_file(Files, Type, File)),
    {Name, Type, File,
     get_template_description(TemplateTerms),
     get_template_vars(TemplateTerms)}.

%% Load up the template description out from a list of attributes read in
%% a .template file.
get_template_description(TemplateTerms) ->
    case lists:keyfind(description, 1, TemplateTerms) of
        {_, Desc} -> Desc;
        false -> undefined
    end.

%% Load up the variables out from a list of attributes read in a .template file
%% and return them merged with the globally-defined and default variables.
get_template_vars(TemplateTerms) ->
    Vars = case lists:keyfind(variables, 1, TemplateTerms) of
        {_, Value} -> Value;
        false -> []
    end,
    override_vars(Vars, override_vars(global_variables(), default_variables())).

%% Provide a way to merge a set of variables with another one. The left-hand
%% set of variables takes precedence over the right-hand set.
%% In the case where left-hand variable description contains overriden defaults, but
%% the right-hand one contains additional data such as documentation, the resulting
%% variable description will contain the widest set of information possible.
override_vars([], General) -> General;
override_vars([{Var, Default} | Rest], General) ->
    case lists:keytake(Var, 1, General) of
        {value, {Var, _Default, Doc}, NewGeneral} ->
            [{Var, Default, Doc} | override_vars(Rest, NewGeneral)];
        {value, {Var, _Default}, NewGeneral} ->
            [{Var, Default} | override_vars(Rest, NewGeneral)];
        false ->
            [{Var, Default} | override_vars(Rest, General)]
    end;
override_vars([{Var, Default, Doc} | Rest], General) ->
    [{Var, Default, Doc} | override_vars(Rest, lists:keydelete(Var, 1, General))].

%% Default variables, generated dynamically.
default_variables() ->
    {{Y,M,D},{H,Min,S}} = calendar:universal_time(),
    [{date, lists:flatten(io_lib:format("~4..0w-~2..0w-~2..0w",[Y,M,D]))},
     {datetime, lists:flatten(io_lib:format("~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0w+00:00",[Y,M,D,H,Min,S]))},
     {author_name, "Anonymous"},
     {author_email, "anonymous@example.org"},
     {copyright_year, integer_to_list(Y)},
     {apps_dir, "apps", "Directory where applications will be created if needed"}].

%% Load variable definitions from the 'Globals' file in the home template
%% directory
global_variables() ->
    Home = rebar_utils:home_dir(),
    GlobalFile = filename:join([Home, ?CONFIG_DIR, "templates", "globals"]),
    case file:consult(GlobalFile) of
        {error, enoent} -> [];
        {ok, Data} -> proplists:get_value(variables, Data, [])
    end.

%% drop the documentation for variables when present
drop_var_docs([]) -> [];
drop_var_docs([{K,V,_}|Rest]) -> [{K,V} | drop_var_docs(Rest)];
drop_var_docs([{K,V}|Rest]) -> [{K,V} | drop_var_docs(Rest)].

%% Load the template index, resolve all variables, and then execute
%% the template.
create({Template, Type, File}, Files, UserVars, Force) ->
    TemplateTerms = consult(load_file(Files, Type, File)),
    Vars = drop_var_docs(override_vars(UserVars, get_template_vars(TemplateTerms))),
    TemplateCwd = filename:dirname(File),
    execute_template(TemplateTerms, Files, {Template, Type, TemplateCwd}, Vars, Force).

%% Run template instructions one at a time.
execute_template([], _, {Template,_,_}, _, _) ->
    ?DEBUG("Template ~s applied~n", [Template]),
    ok;
%% We can't execute the description
execute_template([{description, _} | Terms], Files, Template, Vars, Force) ->
    execute_template(Terms, Files, Template, Vars, Force);
%% We can't execute variables
execute_template([{variables, _} | Terms], Files, Template, Vars, Force) ->
    execute_template(Terms, Files, Template, Vars, Force);
%% Create a directory
execute_template([{dir, Path} | Terms], Files, Template, Vars, Force) ->
    ?DEBUG("Creating directory ~p~n", [Path]),
    case ec_file:mkdir_p(expand_path(Path, Vars)) of
        ok ->
            ok;
        {error, Reason} ->
            ?ABORT("Failed while processing template instruction "
                   "{dir, ~p}: ~p~n", [Path, Reason])
    end,
    execute_template(Terms, Files, Template, Vars, Force);
%% Change permissions on a file
execute_template([{chmod, File, Perm} | Terms], Files, Template, Vars, Force) ->
    Path = expand_path(File, Vars),
    case file:change_mode(Path, Perm) of
        ok ->
            execute_template(Terms, Files, Template, Vars, Force);
        {error, Reason} ->
            ?ABORT("Failed while processing template instruction "
                   "{chmod, ~.8#, ~p}: ~p~n", [Perm, File, Reason])
    end;
%% Create a raw untemplated file
execute_template([{file, From, To} | Terms], Files, {Template, Type, Cwd}, Vars, Force) ->
    ?DEBUG("Creating file ~p~n", [To]),
    Data = load_file(Files, Type, filename:join(Cwd, From)),
    Out = expand_path(To,Vars),
    case write_file(Out, Data, Force) of
        ok -> ok;
        {error, exists} -> ?INFO("File ~p already exists.~n", [Out])
    end,
    execute_template(Terms, Files, {Template, Type, Cwd}, Vars, Force);
%% Operate on a django template
execute_template([{template, From, To} | Terms], Files, {Template, Type, Cwd}, Vars, Force) ->
    ?DEBUG("Executing template file ~p~n", [From]),
    Out = expand_path(To, Vars),
    Tpl = load_file(Files, Type, filename:join(Cwd, From)),
    TplName = make_template_name("rebar_template", Out),
    {ok, Mod} = erlydtl:compile_template(Tpl, TplName, ?ERLYDTL_COMPILE_OPTS),
    {ok, Output} = Mod:render(Vars),
    case write_file(Out, Output, Force) of
        ok -> ok;
        {error, exists} -> ?INFO("File ~p already exists~n", [Out])
    end,
    execute_template(Terms, Files, {Template, Type, Cwd}, Vars, Force);
%% Unknown
execute_template([Instruction|Terms], Files, Tpl={Template,_,_}, Vars, Force) ->
    ?WARN("Unknown template instruction ~p in template ~s",
          [Instruction, Template]),
    execute_template(Terms, Files, Tpl, Vars, Force).

%% Workaround to allow variable substitution in path names without going
%% through the ErlyDTL compilation step. Parse the string and replace
%% as we go.
expand_path([], _) -> [];
expand_path("{{"++Rest, Vars) -> replace_var(Rest, [], Vars);
expand_path([H|T], Vars) -> [H | expand_path(T, Vars)].

%% Actual variable replacement.
replace_var("}}"++Rest, Acc, Vars) ->
    Var = lists:reverse(Acc),
    Val = proplists:get_value(list_to_atom(Var), Vars, ""),
    Val ++ expand_path(Rest, Vars);
replace_var([H|T], Acc, Vars) ->
    replace_var(T, [H|Acc], Vars).

%% Load a list of all the files in the escript and on disk
find_templates(State) ->
    %% Cache the files since we'll potentially need to walk it several times
    %% over the course of a run.
    Files = cache_escript_files(State),

    %% Build a list of available templates
    AvailTemplates = prioritize_templates(
        tag_names(find_disk_templates(State)),
        tag_names(find_escript_templates(Files))),

    ?DEBUG("Available templates: ~p\n", [AvailTemplates]),
    {AvailTemplates, Files}.

%% Scan the current escript for available files
cache_escript_files(State) ->
    {ok, Files} = rebar_utils:escript_foldl(
                    fun(Name, _, GetBin, Acc) ->
                            [{Name, GetBin()} | Acc]
                    end,
                    [], rebar_state:get(State, escript)),
    Files.

%% Find all the template indexes hiding in the rebar3 escript.
find_escript_templates(Files) ->
    [{escript, Name}
     || {Name, _Bin} <- Files,
        re:run(Name, ?TEMPLATE_RE, [{capture, none}]) == match].

%% Fetch template indexes that sit on disk in the user's HOME
find_disk_templates(State) ->
    OtherTemplates = find_other_templates(State),
    Home = rebar_utils:home_dir(),
    HomeFiles = rebar_utils:find_files(filename:join([Home, ?CONFIG_DIR, "templates"]),
                                       ?TEMPLATE_RE),
    LocalFiles = rebar_utils:find_files(".", ?TEMPLATE_RE, true),
    [{file, F} || F <- OtherTemplates ++ HomeFiles ++ LocalFiles].

%% Fetch template indexes that sit on disk in custom areas
find_other_templates(State) ->
    case rebar_state:get(State, template_dir, undefined) of
        undefined ->
            [];
        TemplateDir ->
            rebar_utils:find_files(TemplateDir, ?TEMPLATE_RE)
    end.

%% Take an existing list of templates and tag them by name the way
%% the user would enter it from the CLI
tag_names(List) ->
    [{filename:basename(File, ".template"), Type, File}
     || {Type, File} <- List].

%% If multiple templates share the same name, those in the escript (built-in)
%% take precedence. Otherwise, the on-disk order is the one to win.
prioritize_templates([], Acc) -> Acc;
prioritize_templates([{Name, Type, File} | Rest], Valid) ->
    case lists:keyfind(Name, 1, Valid) of
        false ->
            prioritize_templates(Rest, [{Name, Type, File} | Valid]);
        {_, escript, _} ->
            ?DEBUG("Skipping template ~p, due to presence of a built-in "
                   "template with the same name~n", [Name]),
            prioritize_templates(Rest, Valid);
        {_, file, _} ->
            ?DEBUG("Skipping template ~p, due to presence of a custom "
                   "template at ~s~n", [File]),
            prioritize_templates(Rest, Valid)
    end.


%% Read the contents of a file from the appropriate source
load_file(Files, escript, Name) ->
    {Name, Bin} = lists:keyfind(Name, 1, Files),
    Bin;
load_file(_Files, file, Name) ->
    {ok, Bin} = file:read_file(Name),
    Bin.

%% Given a string or binary, parse it into a list of terms, ala file:consult/1
consult(Str) when is_list(Str) ->
    consult([], Str, []);
consult(Bin) when is_binary(Bin)->
    consult([], binary_to_list(Bin), []).

consult(Cont, Str, Acc) ->
    case erl_scan:tokens(Cont, Str, 0) of
        {done, Result, Remaining} ->
            case Result of
                {ok, Tokens, _} ->
                    {ok, Term} = erl_parse:parse_term(Tokens),
                    consult([], Remaining, [Term | Acc]);
                {eof, _Other} ->
                    lists:reverse(Acc);
                {error, Info, _} ->
                    {error, Info}
            end;
        {more, Cont1} ->
            consult(Cont1, eof, Acc)
    end.


write_file(Output, Data, Force) ->
    %% determine if the target file already exists
    FileExists = filelib:is_regular(Output),

    %% perform the function if we're allowed,
    %% otherwise just process the next template
    case Force orelse FileExists =:= false of
        true ->
            ok = filelib:ensure_dir(Output),
            case {Force, FileExists} of
                {true, true} ->
                    ?INFO("Writing ~s (forcibly overwriting)",
                             [Output]);
                _ ->
                    ?INFO("Writing ~s", [Output])
            end,
            case file:write_file(Output, Data) of
                ok ->
                    ok;
                {error, Reason} ->
                    ?ABORT("Failed to write output file ~p: ~p\n",
                           [Output, Reason])
            end;
        false ->
            {error, exists}
    end.

-spec make_template_name(string(), term()) -> module().
make_template_name(Base, Value) ->
    %% Seed so we get different values each time
    random:seed(erlang:now()),
    Hash = erlang:phash2(Value),
    Ran = random:uniform(10000000),
    erlang:list_to_atom(Base ++ "_" ++
                            erlang:integer_to_list(Hash) ++
                            "_" ++ erlang:integer_to_list(Ran)).

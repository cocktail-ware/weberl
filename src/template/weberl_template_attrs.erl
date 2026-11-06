%% @doc Blocks between the attributes of a start tag (HANDOFF.md, decision 14).
%%
%% `{: if @on :}checked{: /if :}' standing between attributes is a list of whole attributes, and what
%% follows it, `name="x"' say, has to be separated from it. HTML ignores white space between attributes,
%% so the engine supplies it: the body of every branch of a block that stands between attributes is
%% wrapped in a leading and a trailing space. A branch that is not taken, and an `if' without an `else',
%% render nothing, so an absent attribute leaves no white space behind.
%%
%% Inside a quoted attribute value a space is data (`title="Hello{: if @x :}!{: /if :}"'), so nothing is
%% added there. The validation (`weberl_template_parser') has already checked that each branch is a list of
%% whole attributes; this pass only follows the HTML context to find the blocks that stand between them.
%% It changes nothing else, so code generation needs no knowledge of it.
-module(weberl_template_attrs).

-export([prepare/1]).

%% @doc The AST with the bodies of the blocks between attributes wrapped in spaces.
-spec prepare(weberl_template_parser:ast()) -> weberl_template_parser:ast().
prepare(Ast) ->
    walk(Ast, weberl_template_html:initial(), []).

walk([], _Ctx, Acc) ->
    lists:reverse(Acc);
walk([{text, _, Bin} = Node | Rest], Ctx, Acc) ->
    walk(Rest, weberl_template_html:advance(Bin, Ctx), [Node | Acc]);
walk([Node | Rest], Ctx, Acc) ->
    %% the context does not change across a node that is not text: an interpolation is inside a value
    %% or in text, and a block, region, slot or fill ends where it began
    walk(Rest, Ctx, [node(Node, Ctx) | Acc]).

node(Node, Ctx) ->
    Spaced = weberl_template_html:block_context(Ctx) =:= tag andalso is_block(Node),
    weberl_template_parser:map_children(
      fun(Children) ->
              Inner = walk(Children, Ctx, []),
              case Spaced of
                  true -> [{text, line(Node), <<" ">>}] ++ Inner ++ [{text, line(Node), <<" ">>}];
                  false -> Inner
              end
      end, Node).

is_block({'if', _, _, _}) -> true;
is_block({'case', _, _, _}) -> true;
is_block({'for', _, _, _, _}) -> true;
is_block(_) -> false.

line(Node) -> element(2, Node).

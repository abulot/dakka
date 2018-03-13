{-# LANGUAGE FlexibleContexts
           , FlexibleInstances
           , TypeFamilies
           , TypeApplications
           , DefaultSignatures
           , MultiParamTypeClasses
           , FunctionalDependencies
           , DataKinds
           , ExistentialQuantification
           , GeneralizedNewtypeDeriving
           , StandaloneDeriving
           , DeriveDataTypeable
           , PackageImports
           , TypeOperators
           , ConstraintKinds
           , PolyKinds
           , RankNTypes
           , UndecidableInstances
           , UndecidableSuperClasses
#-}
module Dakka.Actor where

import "base" Data.Kind ( Constraint )
import "base" Data.Typeable ( Typeable, cast, typeRep )
import "base" Data.Proxy ( Proxy(..) )
import "containers" Data.Tree ( Tree(..) )

import "transformers" Control.Monad.Trans.State.Lazy ( StateT, execStateT )
import "transformers" Control.Monad.Trans.Writer.Lazy ( Writer, runWriter )
import "base" Control.Monad.IO.Class ( MonadIO( liftIO ) )

import "mtl" Control.Monad.Reader ( ReaderT, ask, MonadReader, runReaderT )
import "mtl" Control.Monad.State.Class ( MonadState, modify )
import "mtl" Control.Monad.Writer.Class ( MonadWriter( tell ) )

import Dakka.Constraints
import Dakka.Type.Path
import Dakka.Type.Tree
import Dakka.Convert


type ActorRef p = IndexedPath p

-- | Execution Context of an 'Actor'.
-- Has to provide ways to:
--
--     * change the state of an `Actor` (through `MonadState`)
--
--     * send messages to other actors
--
--     * create new actors.
-- 
class ( Actor a
      , MonadState a m
      , a ~ Select p t
      ) => ActorContext 
           (t :: Tree *)
           (p :: Path *)
           (a :: *)
           (m :: * -> *)
      | m -> a, m -> p, m -> t where
    {-# MINIMAL self, create', (send | (!)) #-}

    -- | reference to the currently running 'Actor'
    self :: m (ActorRef p)

    -- | Creates a new `Actor` of type 'b' with provided start state
    create' :: (Actor b, b :∈ Creates a) => Proxy b -> m (ActorRef (p ':/ b))

    -- | Send a message to another actor
    send :: Actor (Tip b) => ActorRef b -> Message (Tip b) -> m ()
    send = (!)

    -- | Alias for 'send' to enable akka style inline send.
    (!) :: Actor (Tip b) => ActorRef b -> Message (Tip b) -> m ()
    (!) = send

create :: (Actor b, Actor a, ActorContext t p a m, b :∈ Creates a) => m (ActorRef (p ':/ b))
create = create' Proxy

-- ---------------- --
-- MockActorContext --
-- ---------------- --

-- | Encapsulates an interaction of a behavior with the context
data SystemMessage
    = forall a. Actor a => Create (Proxy a)
    | forall p. Actor (Tip p) => Send
        { to  :: ActorRef p
        , msg :: Message (Tip p)
        }

instance Show SystemMessage where
    showsPrec i (Create p)    str = "Create " ++ show (typeRep p) ++ str
    showsPrec i (Send to msg) str = "Send {to = " ++ show to ++ ", msg = " ++ show msg ++ "}" ++ str

instance Eq SystemMessage where
    (Create a) == (Create b) = a =~= b
    (Send at am) == (Send bt bm) = demotePath at == demotePath bt && am =~= bm

-- | An ActorContext that simply collects all state transitions, sent messages and creation intents.
newtype MockActorContext t p a v = MockActorContext
    (ReaderT (ActorRef p) (StateT a (Writer [SystemMessage])) v)
  deriving (Functor, Applicative, Monad, MonadState a, MonadWriter [SystemMessage], MonadReader (ActorRef p))

instance (Actor a, a ~ Select p t, a ~ Tip p) => ActorContext t p a (MockActorContext t p a) where

    self = ask

    create' a = do
        tell [Create a]
        self <$/> a

    p ! m = tell [Send p m]

-- | Execute a 'Behavior' in a 'MockActorContext'.
execMock :: forall t a p b. (a ~ Select p t) => ActorRef p -> MockActorContext t p a b -> a -> (a, [SystemMessage])
execMock ar (MockActorContext ctx) = runWriter . execStateT (runReaderT ctx ar)


execMock' :: forall t a p b. (a ~ Select p t, Actor a) => ActorRef p -> MockActorContext t p a b -> (a, [SystemMessage])
execMock' ar ctx = execMock ar ctx startState

-- ------- --
--  Actor  --
-- ------- --

-- | A Behavior of an 'Actor' defines how an Actor reacts to a message given a specific state.
-- A Behavior may be executed in any 'ActorContext' that has all of the actors 'Capabillities'.
type Behavior a = forall t p m. (Tip p ~ a, ActorContext t p a m, m `ImplementsAll` Capabillities a) => Message a -> m ()


class (RichData a, RichData (Message a), Actor `ImplementedByAll` Creates a) => Actor (a :: *) where
    -- | List of all types of actors that this actor may create in its lifetime.
    type Creates a :: [*]
    type Creates a = '[]
  
    -- | Type of Message this Actor may recieve
    type Message a :: *

    -- | List of all additional Capabillities the ActorContext has to provide For this Actors Behavior.
    type Capabillities a :: [(* -> *) -> Constraint]
    type Capabillities a = '[]

    -- | This Actors behavior
    behavior :: Behavior a

    startState :: a
    default startState :: Monoid a => a
    startState = mempty

-- | A pure 'Actor' is one that has no additional Capabillities besides what a 
-- 'ActorContext' provides.
type PureActor a = (Actor a, Capabillities a ~ '[])

-- | A leaf 'Actor' is one that doesn't create any children.
type LeafActor a = (Actor a, Creates a ~ '[])

behaviorOf :: Proxy a -> Behavior a 
behaviorOf = const behavior

data AnswerableMessage r = forall p. (Actor (Tip p), Convertible r (Message (Tip p))) => AnswerableMessage
    { askerRef :: ActorRef p
    }
deriving instance Typeable r => Typeable (AnswerableMessage r)
instance Eq (AnswerableMessage r) where
    (AnswerableMessage a) == (AnswerableMessage b) = demotePath a == demotePath b
instance Show (AnswerableMessage r) where
    show (AnswerableMessage a) = "AnswerableMessage " ++ show a

answer :: (Actor a, ActorContext t p a m) => r -> AnswerableMessage r -> m ()
answer r (AnswerableMessage ref) = ref ! convert r

-- ------------- --
--  ActorSystem  --
-- ------------- --

type family ActorSystemTree (r :: [*]) :: Tree * where
    ActorSystemTree r = 'Node () (ActorSystemSubTrees r)

type family ActorSystemSubTrees (r :: [*]) :: [Tree *] where
    ActorSystemSubTrees '[]       = '[]
    ActorSystemSubTrees (a ': as) = ActorSystemSubTree a ': ActorSystemSubTrees as

type family ActorSystemSubTree (a :: *) :: Tree * where
    ActorSystemSubTree a = 'Node a (ActorSystemSubTrees (Creates a))  

-- -------- --
--   Test   --
-- -------- --

-- | Actor with all bells and whistles.
newtype TestActor = TestActor
    { i :: Int
    } deriving (Show, Eq, Typeable)
instance Semigroup TestActor where
    (TestActor i) <> (TestActor j) = TestActor (i + j)
instance Monoid TestActor where
    mempty = TestActor 0
instance Actor TestActor where
  type Message TestActor = String
  type Creates TestActor = '[OtherActor]
  type Capabillities TestActor = '[MonadIO]
  behavior m = do
      modify (TestActor . succ . i)
      liftIO $ putStrLn m
      p <- create @OtherActor
      p ! Msg m

-- | Actor with custom message type.
-- This one also communicates with another actor and expects a response.
newtype Msg = Msg String deriving (Show, Eq, Typeable)
instance Convertible String Msg where
    convert = Msg
data OtherActor = OtherActor deriving (Show, Eq, Typeable)
instance Actor OtherActor where
  type Message OtherActor = Msg
  type Creates OtherActor = '[WithRef]
  behavior m = do
      p <- create @WithRef
      a <- self
      p ! AnswerableMessage a
  startState = OtherActor

-- | Actor that handles references to other Actors
data WithRef = WithRef deriving (Show, Eq, Typeable)
instance Actor WithRef where
    type Message WithRef = AnswerableMessage String
    behavior = answer "hello"
    startState = WithRef
